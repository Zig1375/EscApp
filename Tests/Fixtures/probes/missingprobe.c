/* Imports a DLL that doesn't exist, like a game that isn't fully installed. Windows refuses to start it, the same
   way with every backend, so Magic Kettle should stop after the first attempt. */
#include "common.h"

__declspec(dllimport) int magickettle_missing_function(void);

int main(void) {
    return magickettle_missing_function();
}
