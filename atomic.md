# Atomic increment/decrement operations in SQL (and fun with locks)

## tl;dr;
__SQL supports atomic increment and decrement operations on numeric columns. The "trick" is to use an update query based
on the following pattern:__

```
-- This assumes the existence of a table defined as:
-- CREATE TABLE test(id SERIAL PRIMARY KEY, x INTEGER);
UPDATE test set x = x - 1 where id = 1;
```

There are two important elements in this query:
- The `WHERE` clause has to be invariant and deterministic (more on that [later](#condition)).
- The right hand side of the update statement is using the relative value instead of passing an absolute, preselected
  value (also more on that [later](#rhs)).

The [postgresql documentation](https://www.postgresql.org/docs/9.6/static/transaction-iso.html#XACT-READ-COMMITTED) has
a good example.

## Deadlock risk

It is important to note that since the `UPDATE` query will implicitly use a row level lock, a deadlock can happen if
multiple transactions are running with the isolation level set as `READ COMMITTED`, `REPEATABLE READ` or `SERIALIZABLE`.

### Example

Let's insert two rows in the `test` table.

```sql
insert into test values (1, 0);
insert into test values (2, 0);
```

We can trigger a deadlock with two `psql` sessions:

```sql
$1> psql
psql1> BEGIN;
psql1> UPDATE test SET x = x + 1 WHERE id = 1; -- A lock is acquired on the row with id 1, no other transactions can update it
```

```sql
$2> psql
psql2> BEGIN;
psql2> UPDATE test SET x = x + 1 WHERE id = 2; -- A lock is acquired on the row with id 2, no other transactions can update it
```

```sql
psql1> UPDATE test SET x = x + 1 WHERE id = 2; -- The second session hasn't committed yet, this operation is now waiting
```

```sql
psql2> UPDATE test SET x = x + 1 WHERE id = 1; -- The first session hasn't committed yet, this operation is now waiting
```

DEADLOCK! Each session is waiting for the other one to commit or rollback:

```sql
ERROR:  deadlock detected
DETAIL:  Process 14803 waits for ShareLock on transaction 43356; blocked by process 14431.
Process 14431 waits for ShareLock on transaction 43357; blocked by process 14803.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,1) in relation "test"
```

Postgresql automatically detects the situation after a few seconds and will automatically roll back one of the
transactions, allowing the other one to commit successfully.

_Note: This situation will happen with all transaction isolation levels_

### Solution

One way to prevent this is to use a deterministic ordering when multiple rows are updated in the transations, in this
case, if both transactions had sorted the rows by ascending id for instance, there wouldn't have been any deadlocks.

## <a id="condition"></a>Deterministic Condition

As explained in the postgresql documentation, what makes the increment query safe with a transaction using the `READ
COMMITTED` isolation level is the determinism of the condition used in the `WHERE` clause of the `UPDATE` query.

Let's look at what can happen with a less trivial query:

```sql
$1> psql
psql1> BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
psql1> UPDATE test SET x = x + 1 WHERE id = 2; -- A lock is acquired on the row with id 2, no other transaction can update it
```

```sql
$2> psql
psql2> BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;
psql2> UPDATE test set x = x + 1 WHERE x % 2 = 0;
-- A lock is acquired on all rows with an even x value, since there's a lock on the row with id 2, this query waits for
-- the first transaction to commit or rollback
```

```sql
psql1> UPDATE test set x = x + 1 WHERE x % 2 = 0;
```

This creates another deadlock situation.

The bottom line is: as long as you're using an equality condition on a primary key (or an immutable column) then there
isn't much to worry about. If you don't... well, it's hard to tell what could happen.

__note: Using a restrictive isolation level such as REPEATABLE READ or SERIALIZABLE might actually make things more
complicated as the application code would need to handle serialization failures with some sort of retry logic. There are
examples in the code section at the bottom of the article__

## <a id="rhs"></a>Relative right hand side value

The new value passed to the `UPDATE` query doesn't know what the current value is, and this is what makes this query
work, it'll simply increment the value (after acquiring a lock on the row) to whatever it was plus or minus the given
difference.

If we were to read the value first and use it to compute the new value, we would need to rely on a more complex locking
mechanism to ensure that the value won't change after we read it and before the `UPDATE` is done.

## Real world example

It is common (and probably required) for e-commerce companies to keep track of inventories for each SKU sold on the
platform, a simple inventory table could be defined as:

```sql
CREATE TABLE inventories(sku VARCHAR(3) PRIMARY KEY, quantity INTEGER);
```

A simplified version of our inventory system works as follows:

- Get all the SKUs in the cart
- Sort the SKUs by lexicographic order (to prevent deadlocks)
- Issue one `UPDATE inventories SET quantity = quantity - x WHERE sku = y RETURNING quantity`, where x is the requested
  quantity and y is the actual SKU value. If the returned quantity is too low, an error is thrown and the purchase
  process is aborted.

### Our original (over-engineered) solution

A few years ago, when we wrote one of the first versions of our inventory system at Harry's, we didn't realize that we
could rely on SQL only to issue atomic decrement operations, we ended up using Redis.

Redis supports such operations out of the box ([`INCR`](https://redis.io/commands/incr)
/ [`INCRBY`](https://redis.io/commands/incrby) & [`DECR`](https://redis.io/commands/decr)
/ [`DECRBY`](https://redis.io/commands/decrby)), and being single threaded, doesn't expose any race conditions by
default.

It is definitely a valid implementation (and it worked well for a long time), but it adds a significant operational cost
to the implementation as the inventory data "lives" in two different data stores: Redis and Postgresql.

The implementation can be summarized as:

- We need to decrement the inventory for SKU x
- Is the value in Redis?
- If not, read it from the DB and set in Redis
- Decrement in Redis
- Check the new value, abort if it is too low

## Example code

I wrote a small test suite in Ruby highlighting the different concepts mentioned in this article:

- The "safety" of a relative update query, even in read uncommitted transactions
- The issue with absolute updates in `READ UNCOMMITTED` and `READ COMMITTED` transactions
- An example using `REPEATABLE READ` or `SERIALIZABLE` transactions that requires the application to explicitly handle
  retries for serialization errors.
