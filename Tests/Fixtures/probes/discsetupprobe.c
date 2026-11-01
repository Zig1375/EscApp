/* A stand-in for the setup.exe of a game on several CDs, for the disc-change tests. It runs straight from the
 * first disc (no copy in %TEMP%, the harder case: the disc it runs from leaves the drive) and reads how many discs
 * there are from DISCS.TXT next to itself. Disc N is the CD labelled PROBEDISC<N> holding DATA\PART<N>.DAT, found
 * in the drive setup was started from. Disc 1 also holds the game in GAME\. Like Inno Setup it takes the folder as
 * `/DIR=...`.
 *
 * When the disc in the drive is the wrong one, it asks for the right one in a Retry/Cancel message box, as real
 * installers do. A thread presses Retry once the disc is in (a player would), and Cancel after 90 s, so tests
 * never wait for a click. Each step is printed for the log: "disc N copied", then "SETUP DONE" or "SETUP FAILED". */
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>

const char inno_mark[] = "Inno Setup Setup Data (6.2.2)";

static char drive[] = "D:\\";
static volatile int wanted;

static int disc_in(int n) {
    char label[64], expected[32], file[MAX_PATH];
    snprintf(expected, sizeof expected, "PROBEDISC%d", n);
    snprintf(file, sizeof file, "%sDATA\\PART%d.DAT", drive, n);
    if (!GetVolumeInformationA(drive, label, sizeof label, NULL, NULL, NULL, NULL, 0)) return 0;
    return !strcmp(label, expected) && GetFileAttributesA(file) != INVALID_FILE_ATTRIBUTES;
}

static DWORD WINAPI answer_box(void *unused) {
    for (int i = 0; i < 360; i++) {
        Sleep(250);
        HWND box = FindWindowA("#32770", "Probe Saga Setup");
        if (box && disc_in(wanted)) {
            PostMessageA(box, WM_COMMAND, IDRETRY, 0);
            return 0;
        }
    }
    HWND box = FindWindowA("#32770", "Probe Saga Setup");
    if (box) PostMessageA(box, WM_COMMAND, IDCANCEL, 0);
    return 0;
}

static int ask_for(int n, int total) {
    char text[256];
    while (!disc_in(n)) {
        printf("waiting for disc %d\n", n);
        fflush(stdout);
        wanted = n;
        snprintf(text, sizeof text, "Please insert disc %d of %d of Probe Saga into your CD-ROM drive.", n, total);
        CloseHandle(CreateThread(NULL, 0, answer_box, NULL, 0, NULL));
        if (MessageBoxA(NULL, text, "Probe Saga Setup", MB_RETRYCANCEL | MB_ICONINFORMATION) != IDRETRY) return 0;
    }
    return 1;
}

static int copy(const char *from, const char *dir, const char *name) {
    char source[MAX_PATH], target[MAX_PATH];
    snprintf(source, sizeof source, "%s%s", drive, from);
    snprintf(target, sizeof target, "%s\\%s", dir, name);
    return CopyFileA(source, target, FALSE);
}

static int fail(const char *why) {
    printf("SETUP FAILED: %s\n", why);
    fflush(stdout);
    return 1;
}

int main(int argc, char **argv) {
    const char *dir = "C:\\Program Files\\Probe Saga";
    for (int i = 1; i < argc; i++)
        if (!strncmp(argv[i], "/DIR=", 5)) dir = argv[i] + 5;
    char self[MAX_PATH], list[MAX_PATH], part[32], name[32];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    drive[0] = self[0];
    *strrchr(self, '\\') = 0;
    snprintf(list, sizeof list, "%s\\DISCS.TXT", self);
    FILE *file = fopen(list, "r");
    int total = 0;
    if (!file || fscanf(file, "%d", &total) != 1 || total < 1) return fail("no DISCS.TXT");
    fclose(file);
    SHCreateDirectoryExA(NULL, dir, NULL);

    for (int n = 1; n <= total; n++) {
        if (!ask_for(n, total)) return fail("cancelled");
        if (n == 1 && !copy("GAME\\probegame.exe", dir, "probegame.exe")) return fail("game not copied");
        snprintf(part, sizeof part, "DATA\\PART%d.DAT", n);
        snprintf(name, sizeof name, "PART%d.DAT", n);
        if (!copy(part, dir, name)) return fail("part not copied");
        printf("disc %d copied\n", n);
        fflush(stdout);
    }
    printf("SETUP DONE\n");
    fflush(stdout);
    return 0;
}
