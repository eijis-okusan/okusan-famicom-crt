#pragma once

#include <cstdio>
#include <string>

#ifdef _WIN32
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

/**
 * Lightweight RAII wrapper around platform shared-library loading
 * (`LoadLibraryA` / `GetProcAddress` on Windows, `dlopen` / `dlsym` on POSIX).
 * Keeps OS loader details out of `FamicomCore`.
 */
class DynamicLibrary {
public:
    DynamicLibrary() = default;
    ~DynamicLibrary() { close(); }

    DynamicLibrary(const DynamicLibrary &) = delete;
    DynamicLibrary &operator=(const DynamicLibrary &) = delete;

    bool open(const std::string &path) {
        close();
#ifdef _WIN32
        handle_ = LoadLibraryA(path.c_str());
        if (!handle_) {
            std::fprintf(stderr, "Failed to open library %s (Windows error %lu)\n",
                         path.c_str(), static_cast<unsigned long>(GetLastError()));
            return false;
        }
#else
        handle_ = dlopen(path.c_str(), RTLD_NOW);
        if (!handle_) {
            std::fprintf(stderr, "Failed to open library %s: %s\n", path.c_str(), dlerror());
            return false;
        }
#endif
        return true;
    }

    void close() {
        if (!handle_) return;
#ifdef _WIN32
        FreeLibrary(handle_);
#else
        dlclose(handle_);
#endif
        handle_ = nullptr;
    }

    bool isOpen() const { return handle_ != nullptr; }

    template <typename FnPtr>
    bool resolve(const char *symbolName, FnPtr &outFn) const {
        if (!handle_) {
            outFn = nullptr;
            return false;
        }
#ifdef _WIN32
        outFn = reinterpret_cast<FnPtr>(GetProcAddress(handle_, symbolName));
#else
        outFn = reinterpret_cast<FnPtr>(dlsym(handle_, symbolName));
#endif
        return outFn != nullptr;
    }

private:
#ifdef _WIN32
    HMODULE handle_ = nullptr;
#else
    void *handle_ = nullptr;
#endif
};
