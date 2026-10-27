#import "TMSocket.h"
#import "TMHTTP.h"
#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <algorithm>
#include <string>
#include <dlfcn.h>
#include <map>
#include <os/lock.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#ifndef TM_SOCKET_TEST
extern "C" void MSHookFunction(void *, void *, void **);
#endif

static constexpr unsigned N=4096, Q=2048;
struct FD { int fd=-1, type=0; uint64_t generation=0; sockaddr_storage peer{}; };
struct Event { FD socket; uint64_t up=0,down=0; int operation=0; bool truncated=false; };
static FD fds[N]; static Event events[Q]; static unsigned head, count;
static os_unfair_lock lock=OS_UNFAIR_LOCK_INIT;
static std::atomic<uint64_t> generation{1}, dropped{0}, peeked{0}, failures{0};
static __thread bool inside;
static NSString *session; static uint64_t sequence;
struct Guard { bool previous; Guard():previous(inside){inside=true;} ~Guard(){inside=previous;} };

static decltype(&socket) o_socket=socket;
static decltype(&connect) o_connect=connect;
static decltype(&send) o_send=send; static decltype(&recv) o_recv=recv;
static decltype(&sendto) o_sendto=sendto; static decltype(&recvfrom) o_recvfrom=recvfrom;
static decltype(&sendmsg) o_sendmsg=sendmsg; static decltype(&recvmsg) o_recvmsg=recvmsg;
static decltype(&read) o_read=read; static decltype(&write) o_write=write;
static decltype(&readv) o_readv=readv; static decltype(&writev) o_writev=writev;
static decltype(&close) o_close=close; static decltype(&dup) o_dup=dup;
static decltype(&dup2) o_dup2=dup2;
static decltype(&accept) o_accept=accept;

static void push(const FD &value,uint64_t up,uint64_t down,int op,bool truncated=false) {
    if(value.type==0 || (value.peer.ss_family!=AF_INET && value.peer.ss_family!=AF_INET6)) return;
    if(count==Q){dropped.fetch_add(1);return;}
    Event &e=events[(head+count++)%Q]; e.socket=value;e.up=up;e.down=down;e.operation=op;e.truncated=truncated;
}
// Only called while holding the trylock. Metadata syscalls occur on first use,
// never DNS, disk, SQLite, IPC or waiting for queue space.
static FD &lookup(int fd) {
    FD &v=fds[(unsigned)fd%N];
    if(v.fd!=fd){
        if(v.fd!=-1){dropped.fetch_add(1); static __thread FD ignored; ignored=FD{};return ignored;}
        v=FD{};v.fd=fd;v.generation=generation.fetch_add(1);
        socklen_t size=sizeof(v.type);
        if(getsockopt(fd,SOL_SOCKET,SO_TYPE,&v.type,&size)!=0){v.type=0;return v;}
        size=sizeof(v.peer); if(getpeername(fd,(sockaddr *)&v.peer,&size)!=0)v.peer={};
    }
    return v;
}
static void record(int fd,ssize_t result,bool upload,int flags,const sockaddr *peer,socklen_t size,size_t capacity) {
    if(result<0 || !TMMonitoringEnabled())return;
    if(flags&MSG_PEEK){peeked.fetch_add(1);return;}
    if(!os_unfair_lock_trylock(&lock)){dropped.fetch_add(1);return;}
    FD &v=lookup(fd);
    if(v.type && peer && size>0){v.peer={};memcpy(&v.peer,peer,std::min((size_t)size,sizeof(v.peer)));}
    if(v.type && v.peer.ss_family==0){socklen_t n=sizeof(v.peer);if(getpeername(fd,(sockaddr *)&v.peer,&n)!=0)v.peer={};}
    uint64_t bytes=(uint64_t)result;
    bool truncated=!upload && v.type==SOCK_DGRAM && bytes>capacity;
    if(truncated)bytes=capacity;
    push(v,upload?bytes:0,upload?0:bytes,0,truncated || ((flags&MSG_TRUNC)!=0));
    os_unfair_lock_unlock(&lock);
}
static size_t iovSize(const iovec *iov,int n){size_t total=0;for(int i=0;i<n && i<1024;i++){if(SIZE_MAX-total<iov[i].iov_len)return SIZE_MAX;total+=iov[i].iov_len;}return total;}

static int h_socket(int domain,int type,int protocol){
    if(inside)return o_socket(domain,type,protocol);Guard guard;int r=o_socket(domain,type,protocol),saved=errno;
    if(r>=0 && os_unfair_lock_trylock(&lock)){FD &v=fds[(unsigned)r%N];if(v.fd==r)v=FD{};FD &x=lookup(r);if(domain!=AF_INET && domain!=AF_INET6)x.type=0;os_unfair_lock_unlock(&lock);}errno=saved;return r;
}
static int h_connect(int fd,const sockaddr *address,socklen_t length){
    if(inside)return o_connect(fd,address,length);Guard guard;int r=o_connect(fd,address,length),saved=errno;
    if(TMMonitoringEnabled() && os_unfair_lock_trylock(&lock)){
        FD &v=lookup(fd);if(address && length){v.peer={};memcpy(&v.peer,address,std::min((size_t)length,sizeof(v.peer)));}
        push(v,0,0,r==0?1:(saved==EINPROGRESS?2:3));if(r<0 && saved!=EINPROGRESS)failures.fetch_add(1);os_unfair_lock_unlock(&lock);
    }errno=saved;return r;
}
#define IO_BEGIN(name,args) if(inside)return o_##name args; Guard guard; ssize_t r=o_##name args; int saved=errno
#define IO_END(fd,upload,flags,peer,len,cap) record(fd,r,upload,flags,peer,len,cap); errno=saved;return r
static ssize_t h_send(int fd,const void *b,size_t n,int flags){IO_BEGIN(send,(fd,b,n,flags));IO_END(fd,true,flags,nullptr,0,n);}
static ssize_t h_recv(int fd,void *b,size_t n,int flags){IO_BEGIN(recv,(fd,b,n,flags));IO_END(fd,false,flags,nullptr,0,n);}
static ssize_t h_sendto(int fd,const void *b,size_t n,int flags,const sockaddr *a,socklen_t l){IO_BEGIN(sendto,(fd,b,n,flags,a,l));IO_END(fd,true,flags,a,l,n);}
static ssize_t h_recvfrom(int fd,void *b,size_t n,int flags,sockaddr *a,socklen_t *l){
    if(inside)return o_recvfrom(fd,b,n,flags,a,l);Guard guard;sockaddr_storage peer{};socklen_t length=sizeof(peer);
    sockaddr *target=a?a:(sockaddr *)&peer;socklen_t *size=a?l:&length;
    ssize_t r=o_recvfrom(fd,b,n,flags,target,size);int saved=errno;record(fd,r,false,flags,target,size?*size:0,n);errno=saved;return r;
}
static ssize_t h_sendmsg(int fd,const msghdr *m,int flags){IO_BEGIN(sendmsg,(fd,m,flags));if(r>=0&&m)record(fd,r,true,flags,(const sockaddr *)m->msg_name,m->msg_namelen,iovSize(m->msg_iov,m->msg_iovlen));errno=saved;return r;}
static ssize_t h_recvmsg(int fd,msghdr *m,int flags){IO_BEGIN(recvmsg,(fd,m,flags));if(r>=0&&m)record(fd,r,false,flags|m->msg_flags,(const sockaddr *)m->msg_name,m->msg_namelen,iovSize(m->msg_iov,m->msg_iovlen));errno=saved;return r;}
static ssize_t h_read(int fd,void *b,size_t n){IO_BEGIN(read,(fd,b,n));IO_END(fd,false,0,nullptr,0,n);}
static ssize_t h_write(int fd,const void *b,size_t n){IO_BEGIN(write,(fd,b,n));IO_END(fd,true,0,nullptr,0,n);}
static ssize_t h_readv(int fd,const iovec *v,int n){IO_BEGIN(readv,(fd,v,n));IO_END(fd,false,0,nullptr,0,iovSize(v,n));}
static ssize_t h_writev(int fd,const iovec *v,int n){IO_BEGIN(writev,(fd,v,n));IO_END(fd,true,0,nullptr,0,iovSize(v,n));}
static int h_close(int fd){
    if(inside)return o_close(fd);Guard guard;uint64_t old=0;
    if(os_unfair_lock_trylock(&lock)){FD &v=fds[(unsigned)fd%N];if(v.fd==fd)old=v.generation;os_unfair_lock_unlock(&lock);}
    int r=o_close(fd),saved=errno;
    if(r==0 && os_unfair_lock_trylock(&lock)){FD &v=fds[(unsigned)fd%N];if(v.fd==fd && v.generation==old){if(TMMonitoringEnabled())push(v,0,0,4);v=FD{};}os_unfair_lock_unlock(&lock);}errno=saved;return r;
}
static void cloned(int fd,int result){if(result<0)return;if(!os_unfair_lock_trylock(&lock)){dropped.fetch_add(1);return;}FD copy=lookup(fd);FD &to=fds[(unsigned)result%N];if(to.fd!=-1&&to.fd!=result){dropped.fetch_add(1);os_unfair_lock_unlock(&lock);return;}if(to.fd==result && TMMonitoringEnabled())push(to,0,0,4);copy.fd=result;copy.generation=generation.fetch_add(1);to=copy;os_unfair_lock_unlock(&lock);}
static int h_dup(int fd){if(inside)return o_dup(fd);Guard guard;int r=o_dup(fd),e=errno;cloned(fd,r);errno=e;return r;}
static int h_dup2(int fd,int to){if(inside)return o_dup2(fd,to);Guard guard;int r=o_dup2(fd,to),e=errno;if(fd!=to)cloned(fd,r);errno=e;return r;}
static int h_accept(int fd,sockaddr *a,socklen_t *n){if(inside)return o_accept(fd,a,n);Guard guard;int r=o_accept(fd,a,n),e=errno;if(r>=0&&os_unfair_lock_trylock(&lock)){FD &v=fds[(unsigned)r%N];if(v.fd==r)v=FD{};lookup(r);os_unfair_lock_unlock(&lock);}errno=e;return r;}

BOOL TMSocketInstall(void){
    static BOOL installed=NO;
    if(installed)return YES;
    if(!session)session=NSUUID.UUID.UUIDString;
#ifndef TM_SOCKET_TEST
#define HOOK(name) MSHookFunction((void *)o_##name,(void *)h_##name,(void **)&o_##name)
    HOOK(socket);HOOK(connect);HOOK(send);HOOK(recv);HOOK(sendto);HOOK(recvfrom);HOOK(sendmsg);HOOK(recvmsg);
    HOOK(read);HOOK(write);HOOK(readv);HOOK(writev);HOOK(close);HOOK(dup);HOOK(dup2);HOOK(accept);
#undef HOOK
    installed=YES;
#endif
    return installed;
}
NSDictionary *TMSocketHealth(void){return @{@"dropped":@(dropped.load()),@"peek_ignored":@(peeked.load()),@"connect_failures":@(failures.load()),@"queue_capacity":@(Q)};}
void TMSocketDrain(void){
    Guard guard;
    struct Sum{FD fd;uint64_t up=0,down=0,ops=0;int state=0;bool truncated=false;};
    std::map<std::string,Sum> totals;
    for(unsigned i=0;i<Q;i++){
        Event e;
        os_unfair_lock_lock(&lock);if(!count){os_unfair_lock_unlock(&lock);break;}e=events[head];head=(head+1)%Q;--count;os_unfair_lock_unlock(&lock);
        char ip[INET6_ADDRSTRLEN]={};unsigned port=0;
        if(e.socket.peer.ss_family==AF_INET){auto a=(sockaddr_in *)&e.socket.peer;inet_ntop(AF_INET,&a->sin_addr,ip,sizeof(ip));port=ntohs(a->sin_port);}
        else if(e.socket.peer.ss_family==AF_INET6){auto a=(sockaddr_in6 *)&e.socket.peer;inet_ntop(AF_INET6,&a->sin6_addr,ip,sizeof(ip));port=ntohs(a->sin6_port);}
        std::string key=std::to_string(e.socket.fd)+":"+std::to_string(e.socket.generation)+":"+ip+":"+std::to_string(port);
        Sum &s=totals[key];s.fd=e.socket;s.up+=e.up;s.down+=e.down;++s.ops;if(e.operation)s.state=e.operation;else if(e.up||e.down)s.state=1;s.truncated|=e.truncated;
    }
    if(!session)session=NSUUID.UUID.UUIDString;
    for(const auto &pair:totals){
        const Sum &s=pair.second;NSString *key=[NSString stringWithUTF8String:pair.first.c_str()];
        char ip[INET6_ADDRSTRLEN]={};unsigned port=0;
        if(s.fd.peer.ss_family==AF_INET){auto a=(const sockaddr_in *)&s.fd.peer;inet_ntop(AF_INET,&a->sin_addr,ip,sizeof(ip));port=ntohs(a->sin_port);}
        else{auto a=(const sockaddr_in6 *)&s.fd.peer;inet_ntop(AF_INET6,&a->sin6_addr,ip,sizeof(ip));port=ntohs(a->sin6_port);}
        TMHTTPEnqueue(@{@"kind":@"socket_sample",@"event_id":[NSString stringWithFormat:@"%@:%llu",session,(unsigned long long)++sequence],
            @"connection_id":[session stringByAppendingFormat:@":%@",key],@"pid":@(getpid()),@"bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"<probe>",
            @"time":@(NSDate.date.timeIntervalSince1970),@"fd":@(s.fd.fd),@"protocol":s.fd.type==SOCK_DGRAM?@"UDP":@"TCP",
            @"ip":[NSString stringWithUTF8String:ip],@"port":@(port),@"upload_bytes":@(s.up),@"download_bytes":@(s.down),
            @"operations":@(s.ops),@"truncated":@(s.truncated),@"state":s.state==4?@"closed":s.state==3?@"failed":s.state==2?@"pending":@"open"});
    }
}
BOOL TMSocketSelfTest(void){
    Guard outer; // Run wrappers directly on native CI; no macOS memory patching required.
    inside=false;
    int a=h_socket(AF_INET,SOCK_DGRAM,0),b=h_socket(AF_INET,SOCK_DGRAM,0);bool ok=a>=0&&b>=0;
    sockaddr_in addr{};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(ok)ok=bind(b,(sockaddr *)&addr,sizeof(addr))==0;socklen_t length=sizeof(addr);getsockname(b,(sockaddr *)&addr,&length);
    char data[32]={};errno=EDOM;
    if(ok)ok=h_sendto(a,"abcdef",6,0,(sockaddr *)&addr,sizeof(addr))==6 && errno==EDOM;
    if(ok)ok=h_recvfrom(b,data,32,MSG_PEEK,nullptr,nullptr)==6;
    if(ok)ok=h_recvfrom(b,data,3,0,(sockaddr *)&addr,&length)==3 && memcmp(data,"abc",3)==0;
    h_close(a);h_close(b);
    int listener=h_socket(AF_INET,SOCK_STREAM,0),client=h_socket(AF_INET,SOCK_STREAM,0);
    addr.sin_port=0;ok=ok&&bind(listener,(sockaddr *)&addr,sizeof(addr))==0&&listen(listener,1)==0;
    length=sizeof(addr);getsockname(listener,(sockaddr *)&addr,&length);
    ok=ok&&h_connect(client,(sockaddr *)&addr,sizeof(addr))==0;
    int server=ok?h_accept(listener,nullptr,nullptr):-1;
    iovec vectors[2]={{(void *)"abc",3},{(void *)"de",2}};msghdr message{};message.msg_iov=vectors;message.msg_iovlen=2;
    ok=ok&&h_sendmsg(client,&message,0)==5;
    iovec receiveVector{data,sizeof(data)};message.msg_iov=&receiveVector;message.msg_iovlen=1;
    ok=ok&&h_recvmsg(server,&message,0)==5&&memcmp(data,"abcde",5)==0;
    vectors[0].iov_len=2;vectors[1].iov_len=1;
    ok=ok&&h_writev(client,vectors,2)==3;
    receiveVector.iov_len=3;ok=ok&&h_readv(server,&receiveVector,1)==3;
    ok=ok&&h_write(server,"ok",2)==2&&h_read(client,data,2)==2;
    int alias=h_dup(client);ok=ok&&alias>=0&&h_send(alias,"z",1,0)==1&&h_recv(server,data,1,0)==1;
    ok=ok&&h_dup2(client,alias)==alias;
    h_close(alias);h_close(client);h_close(server);h_close(listener);
    // Successful wrappers preserve the caller's errno; failures preserve libc's error.
    errno=0;ok=ok&&h_send(-1,"x",1,0)==-1&&errno==EBADF;
    int v6a=h_socket(AF_INET6,SOCK_DGRAM,0),v6b=h_socket(AF_INET6,SOCK_DGRAM,0);
    sockaddr_in6 address6{};address6.sin6_len=sizeof(address6);address6.sin6_family=AF_INET6;address6.sin6_addr=in6addr_loopback;
    ok=ok&&bind(v6b,(sockaddr *)&address6,sizeof(address6))==0;length=sizeof(address6);getsockname(v6b,(sockaddr *)&address6,&length);
    ok=ok&&h_sendto(v6a,"6",1,0,(sockaddr *)&address6,sizeof(address6))==1&&h_recvfrom(v6b,data,sizeof(data),0,nullptr,nullptr)==1;
    h_close(v6a);h_close(v6b);inside=true;TMSocketDrain();return ok && peeked.load()>0;
}
