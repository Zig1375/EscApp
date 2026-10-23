/* Imports a DLL that doesn't exist, like a game that isn't fully installed. Windows refuses to start it, the same
   way with every backend, so EscApp should stop after the first attempt. */
#include "common.h"

__declspec(dllimport) int escapp_missing_function(void);

int main(void) {
    return escapp_missing_function();
}
