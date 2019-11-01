#include <unistd.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char *const argv[])
{
    int rc;
    rc = setuid(0);
    if ( rc != 0 )
        {
        printf("setuid returned %d\n", rc);
        exit(1);
        }

    return execv("/usr/bin/mock_cache_umount.sh", argv);
}
