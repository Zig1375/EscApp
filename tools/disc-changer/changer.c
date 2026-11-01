/* Magic Kettle's disc changer: puts another disc in a bottle's CD drive while Wine runs, for installers of games
 * on several CDs ("Please insert disc 2"). Relinking dosdevices from the Mac is enough for files, but Wine's mount
 * manager read the drive's label when it started and keeps it: the installer then still saw disc 1's label and
 * kept asking. Defining the drive again through the mount manager, as winecfg does, makes it link the disc and
 * read its label anew.
 *
 * disc-changer.exe <drive letter> <mount point> <raw device>
 *
 * Prints "changed" and exits 0 when the mount manager took it. */
#include <windows.h>
#include <winioctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Wine's own interface (include/ddk/mountmgr.h): not in the Windows SDK. */
#define IOCTL_MOUNTMGR_DEFINE_UNIX_DRIVE CTL_CODE(0x6d, 32, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)

struct mountmgr_unix_drive {
    ULONG size;
    ULONG type;
    ULONG fs_type;
    DWORD serial;
    ULONGLONG unix_dev;
    WCHAR letter;
    USHORT mount_point_offset;
    USHORT device_offset;
    USHORT label_offset;
};

int main(int argc, char **argv) {
    if (argc != 4 || !argv[1][0]) {
        fprintf(stderr, "usage: disc-changer.exe <drive letter> <mount point> <raw device>\n");
        return 2;
    }
    size_t mount = strlen(argv[2]) + 1, device = strlen(argv[3]) + 1;
    DWORD size = (DWORD)(sizeof(struct mountmgr_unix_drive) + mount + device);
    struct mountmgr_unix_drive *drive = calloc(1, size);
    if (!drive) return 3;
    drive->size = size;
    drive->type = DRIVE_CDROM;
    drive->letter = (WCHAR)(argv[1][0] | 0x20);
    drive->mount_point_offset = sizeof *drive;
    drive->device_offset = (USHORT)(sizeof *drive + mount);
    memcpy((char *)drive + drive->mount_point_offset, argv[2], mount);
    memcpy((char *)drive + drive->device_offset, argv[3], device);

    HANDLE manager = CreateFileW(L"\\\\.\\MountPointManager", GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (manager == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "no mount manager (%lu)\n", GetLastError());
        return 4;
    }
    DWORD returned;
    BOOL ok = DeviceIoControl(manager, IOCTL_MOUNTMGR_DEFINE_UNIX_DRIVE, drive, size, NULL, 0, &returned, NULL);
    CloseHandle(manager);
    if (!ok) {
        fprintf(stderr, "the mount manager refused the drive (%lu)\n", GetLastError());
        return 5;
    }
    printf("changed\n");
    return 0;
}
