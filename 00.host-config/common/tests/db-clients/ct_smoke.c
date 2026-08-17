/*
 * ct_smoke.c - the smallest useful SAP ASE Client-Library program.
 *
 * Allocates a CS context, initialises Client-Library, reads its version back
 * out, then allocates and drops a connection. No ASE server is contacted, so
 * this is a toolchain test: it proves the CT-Lib headers, the libraries and
 * $SYBASE are all wired up, and it fails loudly when they are not.
 *
 * cs_ctx_alloc is the interesting call. It reads the locale and charset trees
 * under $SYBASE, so it is what catches a bundle that links but cannot run.
 *
 * Build (a login shell has SYBASE, SYBASE_OCS and SYBPLATFORM already):
 *   cc -m64 -g -Wall -Wformat=2 -D${SYBPLATFORM}=1 \
 *      -I${SYBASE}/${SYBASE_OCS}/include ct_smoke.c \
 *      -L${SYBASE}/${SYBASE_OCS}/lib \
 *      -lsybct64 -lsybtcl64 -lsybcs64 -lsybcomn64 -lsybintl64 -lsybunic64 \
 *      -Wl,-Bdynamic -ldl -lm -o ct_smoke
 *
 * Threaded applications link the _r64 libraries and build with
 * -D_REENTRANT -Dnthread_linuxamd64=1 instead.
 */

#include <stdio.h>
#include <ctpublic.h>

int main(void)
{
    CS_CONTEXT    *ctx  = NULL;
    CS_CONNECTION *conn = NULL;
    CS_INT         outlen;
    CS_CHAR        verbuf[256];

    if (cs_ctx_alloc(CS_VERSION_160, &ctx) != CS_SUCCEED) {
        fprintf(stderr, "cs_ctx_alloc failed - is SYBASE set?\n");
        return 1;
    }
    if (ct_init(ctx, CS_VERSION_160) != CS_SUCCEED) {
        fprintf(stderr, "ct_init failed\n");
        return 1;
    }
    if (ct_config(ctx, CS_GET, CS_VER_STRING, verbuf,
                  (CS_INT)sizeof(verbuf), &outlen) != CS_SUCCEED) {
        fprintf(stderr, "ct_config(CS_VER_STRING) failed\n");
        return 1;
    }
    printf("Client-Library: %s\n", verbuf);

    if (ct_con_alloc(ctx, &conn) != CS_SUCCEED) {
        fprintf(stderr, "ct_con_alloc failed\n");
        return 1;
    }
    ct_con_props(conn, CS_SET, CS_USERNAME, "smoke", CS_NULLTERM, NULL);

    ct_con_drop(conn);
    ct_exit(ctx, CS_UNUSED);
    cs_ctx_drop(ctx);

    printf("ct_smoke: ok\n");
    return 0;
}
