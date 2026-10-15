# Story 19-1 — `suspense_timeout` and a query running in PostgreSQL

Written by `./run postgres`: PostgreSQL 14.19 (Homebrew), pg 1.7.0, Active Record 8.1.4,
Ruby 3.4.5. A throwaway server, one query at a time.

| what | took | what the caller got | on the server | after |
| --- | --- | --- | --- | --- |
| `Timeout.timeout(1)` around `SELECT pg_sleep(4)` | 1.01s | Timeout::Error: execution expired | queries still running on the server right after: 1 | the same connection's next query: 1 in 3.02s |
| `SET LOCAL statement_timeout = '1s'` around `SELECT pg_sleep(4)` | 1.00s | ActiveRecord::QueryCanceled | queries still running on the server right after: 0 |  |
