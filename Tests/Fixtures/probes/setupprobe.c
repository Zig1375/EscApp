/* A stand-in for an old game's setup.exe, for the installer tests. Like Inno Setup it takes the folder as
 * `/DIR=...`, and like it the program started first hands the work to a copy of itself in %TEMP% and exits at
 * once, so EscApp has to wait for the bottle rather than for setup.exe. The copy installs the files in GAME\ next
 * to setup.exe, writes an uninstaller, a registry key and Start menu shortcuts made through the shell. */
#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <stdio.h>

/* Makes EscApp's detection see Inno Setup, or with -DNSIS_STYLE NSIS, which also reads its folder the way NSIS
 * does: raw from the command line, after an unquoted " /D=" that must come last. */
#ifdef NSIS_STYLE
const char nsis_mark[] = "NullsoftInst";
#else
const char inno_mark[] = "Inno Setup Setup Data (6.2.2)";
#endif

static void shortcut(const wchar_t *target, const wchar_t *link) {
    IShellLinkW *shell = NULL;
    IPersistFile *file = NULL;
    if (FAILED(CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&shell)))
        return;
    IShellLinkW_SetPath(shell, target);
    if (SUCCEEDED(IShellLinkW_QueryInterface(shell, &IID_IPersistFile, (void **)&file))) {
        IPersistFile_Save(file, link, TRUE);
        IPersistFile_Release(file);
    }
    IShellLinkW_Release(shell);
}

static int install(const wchar_t *source, const wchar_t *dir) {
    wchar_t from[MAX_PATH], to[MAX_PATH], programs[MAX_PATH], folder[MAX_PATH], link[MAX_PATH];
    const wchar_t *files[] = {L"probegame.exe", L"probe_config.exe"};
    SHCreateDirectoryExW(NULL, dir, NULL);
    for (int i = 0; i < 2; i++) {
        swprintf(from, MAX_PATH, L"%ls\\GAME\\%ls", source, files[i]);
        swprintf(to, MAX_PATH, L"%ls\\%ls", dir, files[i]);
        if (!CopyFileW(from, to, FALSE)) return 2;
    }
    swprintf(to, MAX_PATH, L"%ls\\unins000.exe", dir);
    GetModuleFileNameW(NULL, from, MAX_PATH);
    CopyFileW(from, to, FALSE);

    HKEY key;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, L"Software\\ProbeStudio\\Probe Game", 0, NULL, 0, KEY_WRITE, NULL, &key,
                        NULL) == ERROR_SUCCESS) {
        RegSetValueExW(key, L"InstallPath", 0, REG_SZ, (const BYTE *)dir, (DWORD)((wcslen(dir) + 1) * 2));
        RegCloseKey(key);
    }

    CoInitialize(NULL);
    SHGetFolderPathW(NULL, CSIDL_PROGRAMS, NULL, 0, programs);
    swprintf(folder, MAX_PATH, L"%ls\\Probe Game", programs);
    CreateDirectoryW(folder, NULL);
    swprintf(to, MAX_PATH, L"%ls\\probegame.exe", dir);
    swprintf(link, MAX_PATH, L"%ls\\Probe Game.lnk", folder);
    shortcut(to, link);
    swprintf(to, MAX_PATH, L"%ls\\unins000.exe", dir);
    swprintf(link, MAX_PATH, L"%ls\\Uninstall Probe Game.lnk", folder);
    shortcut(to, link);
    CoUninitialize();
    return 0;
}

int wmain(int argc, wchar_t **argv) {
    const wchar_t *dir = L"C:\\Program Files\\Probe Game";
    const wchar_t *source = NULL;
    for (int i = 1; i < argc; i++) {
        if (!wcsncmp(argv[i], L"/DIR=", 5)) dir = argv[i] + 5;
        if (!wcsncmp(argv[i], L"/SOURCE=", 8)) source = argv[i] + 8;
    }
#ifdef NSIS_STYLE
    const wchar_t *raw = wcsstr(GetCommandLineW(), L" /D=");
    if (!source && raw) dir = raw + 4;
#endif
    if (source) {
        Sleep(1500);
        return install(source, dir);
    }
    /* The first program: copy itself to %TEMP% and let the copy work, as Inno's setup.tmp does. */
    wchar_t self[MAX_PATH], temp[MAX_PATH], copy[MAX_PATH], here[MAX_PATH], line[2048];
    GetModuleFileNameW(NULL, self, MAX_PATH);
    wcscpy(here, self);
    *wcsrchr(here, L'\\') = 0;
    GetTempPathW(MAX_PATH, temp);
    swprintf(copy, MAX_PATH, L"%lssetup.tmp.exe", temp);
    if (!CopyFileW(self, copy, FALSE)) return 3;
    swprintf(line, 2048, L"\"%ls\" \"/DIR=%ls\" \"/SOURCE=%ls\"", copy, dir, here);
    STARTUPINFOW startup = {sizeof startup};
    PROCESS_INFORMATION process;
    if (!CreateProcessW(copy, line, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) return 4;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 0;
}
