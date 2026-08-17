/*
 * sa_smoke.c - the smallest useful SAP SQL Anywhere C API program.
 *
 * This is the client side of IQ. The API is reached through the loader the
 * bundle ships (sdk/c/sacapidll.c), which dlopens libdbcapi_r.so rather than
 * linking it, so the build needs only the headers.
 *
 * sqlany_init is the interesting call: it resolves the message catalogues
 * under $SQLANY16, so a client that links perfectly still fails here if that
 * variable is missing.
 *
 * Build (sacapidll.c is copied out of the bundle by the harness):
 *   cc -Wall -O2 -I${SQLANY16}/sdk/include sa_smoke.c sacapidll.c -ldl -o sa_smoke
 */

#include <stdio.h>
#include "sacapidll.h"

int main(void)
{
    SQLAnywhereInterface api;
    unsigned max_version = 0;

    if (!sqlany_initialize_interface(&api, NULL)) {
        fprintf(stderr, "could not load libdbcapi_r.so - is lib64 on the "
                        "linker path?\n");
        return 1;
    }
    if (!api.sqlany_init("sa_smoke", SQLANY_API_VERSION_1, &max_version)) {
        fprintf(stderr, "sqlany_init failed - is SQLANY16 set?\n");
        return 1;
    }
    printf("SQL Anywhere C API max version: %u\n", max_version);

    api.sqlany_fini();
    sqlany_finalize_interface(&api);

    printf("sa_smoke: ok\n");
    return 0;
}
