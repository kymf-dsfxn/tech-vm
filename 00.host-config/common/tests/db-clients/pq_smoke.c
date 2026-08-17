/*
 * pq_smoke.c - the smallest useful PostgreSQL libpq program.
 *
 * Reports the client library version and builds a connection object without
 * waiting on a server, so it runs anywhere. A toolchain test, not a
 * connectivity test.
 *
 * The header is the point of this one. libpq-dev installs libpq-fe.h under
 * /usr/include/postgresql, not /usr/include, so `cc pq_smoke.c -lpq` alone
 * does NOT find it. Build it the way a real project would:
 *
 *   cc -Wall -Wextra -O2 pq_smoke.c $(pkg-config --cflags --libs libpq) -o pq_smoke
 *
 * or, without pkg-config:
 *
 *   cc -Wall -O2 -I$(pg_config --includedir) pq_smoke.c -lpq -o pq_smoke
 */

#include <stdio.h>
#include <libpq-fe.h>

int main(void)
{
    PGconn *conn;

    printf("libpq version: %d\n", PQlibVersion());
    printf("thread safe:   %d\n", PQisthreadsafe());

    /* PQconnectStart is non-blocking: it builds the object and returns
       without waiting on the server, so no postgres needs to be running. */
    conn = PQconnectStart("host=127.0.0.1 port=5432 dbname=postgres");
    if (conn == NULL) {
        fprintf(stderr, "PQconnectStart returned NULL\n");
        return 1;
    }
    printf("conn status:   %d\n", (int)PQstatus(conn));
    PQfinish(conn);

    printf("pq_smoke: ok\n");
    return 0;
}
