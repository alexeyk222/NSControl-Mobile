// Copies a file into GARMIN/Apps on a USB-connected Garmin watch over MTP.
// libmtp's path lookup fails on fēnix 7 (unknown VID/PID), so the folder is
// located by name and the upload targets its object id directly.
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

static uint32_t find_child(LIBMTP_mtpdevice_t *dev, uint32_t storage, uint32_t parent, const char *name) {
  uint32_t found = 0;
  LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(dev, storage, parent);
  while (files) {
    LIBMTP_file_t *next = files->next;
    if (!found && files->filename && strcasecmp(files->filename, name) == 0) found = files->item_id;
    LIBMTP_destroy_file_t(files);
    files = next;
  }
  return found;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s <local.prg> <REMOTE.PRG>\n", argv[0]); return 2; }
  struct stat st;
  if (stat(argv[1], &st) != 0) { perror(argv[1]); return 2; }
  LIBMTP_Init();
  LIBMTP_raw_device_t *raw = NULL; int count = 0;
  if (LIBMTP_Detect_Raw_Devices(&raw, &count) != LIBMTP_ERROR_NONE || count < 1) {
    fprintf(stderr, "No MTP device. Connect the watch by USB and close Garmin Express.\n"); return 1;
  }
  LIBMTP_mtpdevice_t *dev = LIBMTP_Open_Raw_Device_Uncached(&raw[0]);
  if (!dev || LIBMTP_Get_Storage(dev, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0 || !dev->storage) {
    fprintf(stderr, "Cannot open device storage\n"); return 1;
  }
  uint32_t storage = dev->storage->id;
  uint32_t garmin = find_child(dev, storage, LIBMTP_FILES_AND_FOLDERS_ROOT, "GARMIN");
  uint32_t apps = garmin ? find_child(dev, storage, garmin, "Apps") : 0;
  if (!apps) { fprintf(stderr, "GARMIN/Apps not found\n"); LIBMTP_Release_Device(dev); return 1; }
  uint32_t old = find_child(dev, storage, apps, argv[2]);
  if (old) {
    if (LIBMTP_Delete_Object(dev, old) != 0) { LIBMTP_Dump_Errorstack(dev); fprintf(stderr, "Cannot replace %s\n", argv[2]); return 1; }
    printf("Replaced previous %s\n", argv[2]);
  }
  LIBMTP_file_t *file = LIBMTP_new_file_t();
  file->filename = strdup(argv[2]); file->filesize = (uint64_t)st.st_size;
  file->filetype = LIBMTP_FILETYPE_UNKNOWN; file->parent_id = apps; file->storage_id = storage;
  int rc = LIBMTP_Send_File_From_File(dev, argv[1], file, NULL, NULL);
  if (rc != 0) LIBMTP_Dump_Errorstack(dev);
  else printf("Copied to GARMIN/Apps/%s (%lld bytes). Disconnect USB to install.\n", argv[2], (long long)st.st_size);
  LIBMTP_destroy_file_t(file);
  LIBMTP_Release_Device(dev);
  free(raw);
  return rc != 0;
}
