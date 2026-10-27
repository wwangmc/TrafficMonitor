#pragma once
#include <atomic>
#include <cstdint>
#include <thread>
#include <vector>

// Local diagnostic fixture only; never linked into the injected dylib.
class TMFixture {
    int listener_ = -1;
    uint16_t port_ = 0;
    std::atomic<bool> running_{false};
    std::thread acceptThread_;
    std::vector<std::thread> clients_;
    void acceptLoop();
    static void serve(int fd);
public:
    bool start();
    uint16_t port() const { return port_; }
    void stop();
    ~TMFixture() { stop(); }
};
