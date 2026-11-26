/*
 * Myskef Steam window fix — a stand-in winmm.dll for steamwebhelper.exe only.
 *
 * Steam's window is a Chromium browser (steamwebhelper.exe). Chromium draws
 * its window from a separate "GPU" helper process, and Wine's macOS driver
 * can't show a window drawn by another process, so Steam stays black.
 * Chromium's --in-process-gpu switch moves that drawing into the main
 * browser process, which Wine can show.
 *
 * Myskef tells Wine to load this DLL as winmm.dll in steamwebhelper.exe only
 * (HKCU\Software\Wine\AppDefaults\steamwebhelper.exe\DllOverrides). When it
 * loads, before Chromium reads its command line, it adds --in-process-gpu to
 * the main browser process's command line (not to its --type=… helpers).
 * If the MYSKEF_CEF_EXTRA environment variable is set (Myskef sets it for
 * Steam's "software drawing" mode), its switches are added too.
 * Every winmm function is forwarded to winmm_orig.dll, a copy of Wine's own
 * winmm.dll (see winmm.def). No Steam files are changed.
 */

typedef unsigned short WCHAR;
typedef int BOOL;
typedef unsigned long DWORD;
typedef unsigned long long SIZE_T;
typedef void *HANDLE;
typedef void *HMODULE;

__declspec(dllimport) HMODULE __stdcall GetModuleHandleW(const WCHAR *name);
__declspec(dllimport) void *__stdcall GetProcAddress(HMODULE mod, const char *name);
__declspec(dllimport) BOOL __stdcall VirtualProtect(void *addr, SIZE_T size, DWORD prot, DWORD *old);
__declspec(dllimport) HANDLE __stdcall GetProcessHeap(void);
__declspec(dllimport) void *__stdcall HeapAlloc(HANDLE heap, DWORD flags, SIZE_T size);
__declspec(dllimport) BOOL __stdcall FlushInstructionCache(HANDLE proc, const void *addr, SIZE_T size);
__declspec(dllimport) HANDLE __stdcall GetCurrentProcess(void);
__declspec(dllimport) DWORD __stdcall GetEnvironmentVariableW(const WCHAR *name, WCHAR *buf, DWORD size);

#define PAGE_EXECUTE_READWRITE 0x40
#define PAGE_READWRITE 0x04

static WCHAR extraW[1024] = L" --in-process-gpu";
static char extraA[1024];

static WCHAR *new_cmdW;
static char *new_cmdA;

static SIZE_T lenW(const WCHAR *s) { SIZE_T n = 0; while (s[n]) n++; return n; }
static SIZE_T lenA(const char *s) { SIZE_T n = 0; while (s[n]) n++; return n; }

static int containsW(const WCHAR *s, const WCHAR *sub)
{
    SIZE_T i, j;
    for (i = 0; s[i]; i++)
    {
        for (j = 0; sub[j] && s[i + j] == sub[j]; j++) ;
        if (!sub[j]) return 1;
    }
    return 0;
}

static WCHAR *__stdcall my_GetCommandLineW(void) { return new_cmdW; }
static char *__stdcall my_GetCommandLineA(void) { return new_cmdA; }

/* Make `func` return `value` from now on.
 * Wine's GetCommandLineW/A are "return command_line;", compiled to
 * "mov rax, [rip+disp32]; ret". If that's what we find, just point the
 * variable it reads at our new string. Otherwise jump to our replacement. */
static void redirect(void *func, void *value, void *replacement)
{
    unsigned char *p = func;
    DWORD old;
    int i;

    for (i = 0; i < 16; i++)
    {
        if (p[i] == 0x48 && p[i + 1] == 0x8b && p[i + 2] == 0x05)
        {
            int disp = *(int *)(p + i + 3);
            void **var = (void **)(p + i + 7 + disp);
            if (VirtualProtect(var, sizeof(void *), PAGE_READWRITE, &old))
            {
                *var = value;
                VirtualProtect(var, sizeof(void *), old, &old);
                return;
            }
            break;
        }
        if (p[i] == 0xc3) break;  /* reached "ret" without finding it */
    }
    /* fallback: mov rax, imm64 ; jmp rax */
    if (VirtualProtect(p, 12, PAGE_EXECUTE_READWRITE, &old))
    {
        p[0] = 0x48; p[1] = 0xb8;
        *(void **)(p + 2) = replacement;
        p[10] = 0xff; p[11] = 0xe0;
        VirtualProtect(p, 12, old, &old);
        FlushInstructionCache(GetCurrentProcess(), p, 12);
    }
}

BOOL __stdcall DllMain(HANDLE inst, DWORD reason, void *reserved)
{
    HMODULE kb;
    WCHAR *(__stdcall *getW)(void);
    char *(__stdcall *getA)(void);
    WCHAR *cmdW;
    char *cmdA;
    SIZE_T n, m, i;

    (void)inst; (void)reserved;
    if (reason != 1 /* DLL_PROCESS_ATTACH */) return 1;

    if (!(kb = GetModuleHandleW(L"kernelbase.dll")) && !(kb = GetModuleHandleW(L"kernel32.dll"))) return 1;
    getW = (WCHAR *(__stdcall *)(void))GetProcAddress(kb, "GetCommandLineW");
    getA = (char *(__stdcall *)(void))GetProcAddress(kb, "GetCommandLineA");
    if (!getW) return 1;

    cmdW = getW();
    if (!cmdW) return 1;
    /* only the main browser process; helpers have --type=… */
    if (containsW(cmdW, L"--type=") || containsW(cmdW, L"--in-process-gpu")) return 1;

    /* optional extra switches from Myskef */
    {
        SIZE_T base = lenW(extraW);
        extraW[base] = ' ';
        if (GetEnvironmentVariableW(L"MYSKEF_CEF_EXTRA", extraW + base + 1, 1000 - (DWORD)base) == 0)
            extraW[base] = 0;
        for (i = 0; extraW[i] && i < 1023; i++) extraA[i] = (char)extraW[i];  /* switches are ASCII */
        extraA[i] = 0;
    }

    n = lenW(cmdW);
    m = lenW(extraW);
    new_cmdW = HeapAlloc(GetProcessHeap(), 0, (n + m + 1) * sizeof(WCHAR));
    if (!new_cmdW) return 1;
    for (i = 0; i < n; i++) new_cmdW[i] = cmdW[i];
    for (i = 0; i <= m; i++) new_cmdW[n + i] = extraW[i];
    redirect((void *)getW, new_cmdW, (void *)my_GetCommandLineW);

    if (getA && (cmdA = getA()))
    {
        n = lenA(cmdA);
        m = lenA(extraA);
        new_cmdA = HeapAlloc(GetProcessHeap(), 0, n + m + 1);
        if (new_cmdA)
        {
            for (i = 0; i < n; i++) new_cmdA[i] = cmdA[i];
            for (i = 0; i <= m; i++) new_cmdA[n + i] = extraA[i];
            redirect((void *)getA, new_cmdA, (void *)my_GetCommandLineA);
        }
    }
    return 1;
}
