/*! child.h - starts a program whose output colib can read: its stdout is a named pipe whose end
 * here is overlapped, so colib::read waits on it like on a socket, and reads 0 once the program
 * has exited (colib reads a broken pipe as the end of the stream). No thread waits on it.
 *
 * Its stdin is a file and its stderr another, both in a folder given; it inherits those three
 * handles and nothing else (PROC_THREAD_ATTRIBUTE_HANDLE_LIST): sockets are inheritable on
 * Windows, and a child holding the relay's socket would keep it open after this side closed it.
 * It starts suspended and runs only once it is in a job that ends it when this process ends.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <string>
#include <vector>

struct child_t {
    HANDLE proc = NULL;
    HANDLE out = INVALID_HANDLE_VALUE;      /*!< the pipe's overlapped end: the child's stdout */
};

/*! Returns this process's environment without the variables named, as CreateProcess takes it:
 * NAME=value strings one after another, each ended by a 0, the whole ended by another. */
inline std::string env_without(const std::vector<std::string> &names) {
    std::string block;
    char *env = GetEnvironmentStringsA();
    for (const char *p = env; *p; p += strlen(p) + 1) {
        std::string entry = p;
        std::string name = entry.substr(0, entry.find('=', 1));
        bool drop = false;
        for (const std::string &n : names)
            drop = drop || _stricmp(n.c_str(), name.c_str()) == 0;
        if (!drop)
            block += entry + '\0';
    }
    FreeEnvironmentStringsA(env);
    return block + '\0';
}

/*! Returns a job that kills the processes in it when this process ends, however it ends: a
 * child is put in it before it runs, so closing this window never leaves one running. */
inline HANDLE children_job() {
    static HANDLE job = [] {
        HANDLE j = CreateJobObjectA(NULL, NULL);
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {};
        li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(j, JobObjectExtendedLimitInformation, &li, sizeof(li));
        return j;
    }();
    return job;
}

/*! Opens the pipe the child writes its stdout to: `ours`, overlapped, for reading, and `theirs`,
 * inheritable, for the child. False when Windows refuses. */
inline bool open_out_pipe(HANDLE &ours, HANDLE &theirs) {
    static int count = 0;
    std::string name = "\\\\.\\pipe\\claude-oc-" + std::to_string(GetCurrentProcessId()) + "-"
                     + std::to_string(++count);
    ours = CreateNamedPipeA(name.c_str(), PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED
                            | FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 0,
                            1 << 16, 0, NULL);
    if (ours == INVALID_HANDLE_VALUE)
        return false;
    SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
    theirs = CreateFileA(name.c_str(), GENERIC_WRITE, 0, &sa, OPEN_EXISTING, 0, NULL);
    if (theirs == INVALID_HANDLE_VALUE) {
        CloseHandle(ours);
        return false;
    }
    return true;
}

/*! Starts `cmdline` in `folder`, with stdin read from `in_file` and stderr written to
 * `err_file`, and with the environment `env` (env_without()). False, with the reason in `why`,
 * when it does not start. */
inline bool start_child(const std::string &cmdline, const std::string &folder,
                        const std::string &in_file, const std::string &err_file,
                        std::string env, child_t &ch, std::string &why) {
    SECURITY_ATTRIBUTES sa = {sizeof(sa), NULL, TRUE};
    HANDLE in = CreateFileA(in_file.c_str(), GENERIC_READ, FILE_SHARE_READ, &sa, OPEN_EXISTING,
                            0, NULL);
    HANDLE err = CreateFileA(err_file.c_str(), GENERIC_WRITE, FILE_SHARE_READ, &sa,
                             CREATE_ALWAYS, 0, NULL);
    HANDLE out = INVALID_HANDLE_VALUE;
    bool ok = in != INVALID_HANDLE_VALUE && err != INVALID_HANDLE_VALUE
           && open_out_pipe(ch.out, out);
    if (ok) {
        HANDLE only[3] = {in, out, err};
        SIZE_T size = 0;
        InitializeProcThreadAttributeList(NULL, 1, 0, &size);
        std::vector<char> list_mem(size);
        auto list = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(list_mem.data());
        STARTUPINFOEXA si = {};
        si.StartupInfo.cb = sizeof(si);
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = in;
        si.StartupInfo.hStdOutput = out;
        si.StartupInfo.hStdError = err;
        si.lpAttributeList = list;
        PROCESS_INFORMATION pi = {};
        std::string line = cmdline;
        ok = InitializeProcThreadAttributeList(list, 1, 0, &size)
          && UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, only,
                                       sizeof(only), NULL, NULL)
          && CreateProcessA(NULL, line.data(), NULL, NULL, TRUE, CREATE_NO_WINDOW
                            | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, env.data(),
                            folder.c_str(), &si.StartupInfo, &pi);
        DeleteProcThreadAttributeList(list);
        if (ok) {
            AssignProcessToJobObject(children_job(), pi.hProcess);
            ResumeThread(pi.hThread);
            CloseHandle(pi.hThread);
            ch.proc = pi.hProcess;
        } else {
            CloseHandle(ch.out);
            ch.out = INVALID_HANDLE_VALUE;
        }
    }
    if (!ok)
        why = "Windows error " + std::to_string(GetLastError());
    for (HANDLE h : {in, err, out})     /* the child's ends: its exit must end the stream */
        if (h != INVALID_HANDLE_VALUE)
            CloseHandle(h);
    return ok;
}

/*! Waits for the child to be gone (its stdout has ended) and returns its exit code. */
inline DWORD end_child(child_t &ch) {
    DWORD code = DWORD(-1);
    if (ch.proc) {
        WaitForSingleObject(ch.proc, 10000);
        GetExitCodeProcess(ch.proc, &code);
        CloseHandle(ch.proc);
    }
    if (ch.out != INVALID_HANDLE_VALUE)
        CloseHandle(ch.out);
    ch = child_t{};
    return code;
}
