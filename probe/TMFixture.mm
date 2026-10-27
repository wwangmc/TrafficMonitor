#include "TMFixture.h"
#include <algorithm>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

bool TMFixture::start() {
    listener_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listener_ < 0) return false;
    sockaddr_in address{};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener_, (sockaddr *)&address, sizeof(address)) != 0 || listen(listener_, 64) != 0) {
        close(listener_); listener_ = -1; return false;
    }
    socklen_t size = sizeof(address);
    if (getsockname(listener_, (sockaddr *)&address, &size) != 0) return false;
    port_ = ntohs(address.sin_port);
    running_.store(true);
    acceptThread_ = std::thread([this] { acceptLoop(); });
    return true;
}

void TMFixture::acceptLoop() {
    while (running_.load()) {
        pollfd event{listener_, POLLIN, 0};
        if (poll(&event, 1, 100) <= 0 || !(event.revents & POLLIN)) continue;
        int fd = accept(listener_, nullptr, nullptr);
        if (fd < 0) continue;
        if (clients_.size() >= 128) { close(fd); continue; }
        clients_.emplace_back([fd] { serve(fd); });
    }
}

static bool sendAll(int fd, const std::string &value) {
    size_t offset = 0;
    while (offset < value.size()) {
        ssize_t size = send(fd, value.data() + offset, value.size() - offset, 0);
        if (size < 0 && errno == EINTR) continue;
        if (size <= 0) return false;
        offset += (size_t)size;
    }
    return true;
}

void TMFixture::serve(int fd) {
    int noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    timeval timeout{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    std::string request;
    char buffer[2048];
    size_t headerEnd = std::string::npos, bodySize = 0;
    while (request.size() < 8192) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count <= 0) { close(fd); return; }
        request.append(buffer, (size_t)count);
        headerEnd = request.find("\r\n\r\n");
        if (headerEnd == std::string::npos) continue;
        std::string lower = request.substr(0, headerEnd);
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return (char)std::tolower(c); });
        size_t length = lower.find("\r\ncontent-length:");
        if (length != std::string::npos) bodySize = (size_t)std::strtoul(lower.c_str() + length + 17, nullptr, 10);
        if (bodySize > 4096) { close(fd); return; }
        if (request.size() >= headerEnd + 4 + bodySize) break;
    }
    if (headerEnd == std::string::npos) { close(fd); return; }
    size_t first = request.find(' '), last = request.find(' ', first + 1);
    if (first == std::string::npos || last == std::string::npos) { close(fd); return; }
    std::string target = request.substr(first + 1, last - first - 1);
    std::string path = target.substr(0, target.find('?'));
    if (path == "/disconnect") { close(fd); return; }
    if (path == "/delay") std::this_thread::sleep_for(std::chrono::seconds(2));
    int status = path == "/missing" ? 404 : (path == "/redirect" ? 302 : 200);
    std::string body = path == "/post" ? request.substr(headerEnd + 4, bodySize) :
                       (path == "/final" ? "final-ok" : (path == "/missing" ? "not-found" : "get-ok"));
    std::string headers = "HTTP/1.1 " + std::to_string(status) + " Test\r\nConnection: close\r\nContent-Type: text/plain\r\n";
    if (status == 302) headers += "Location: /final?token=tm_probe_redirect_secret\r\n";
    headers += "Content-Length: " + std::to_string(body.size()) + "\r\n\r\n";
    sendAll(fd, headers + body);
    close(fd);
}

void TMFixture::stop() {
    if (!running_.exchange(false)) return;
    if (acceptThread_.joinable()) acceptThread_.join();
    close(listener_); listener_ = -1;
    for (std::thread &client : clients_) if (client.joinable()) client.join();
    clients_.clear();
}
