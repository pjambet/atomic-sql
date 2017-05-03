# Atomic increment/decrement operations in SQL (and fun with locks) 

## tl;dr;
__It is surprisingly easy to issue atomic increment and decrement operations in SQL on a numeric column. The
"trick" is to use an update query following this pattern:__

```
-- This assumes the existence of a table with a schema defined as:
-- CREATE TABLE test(id SERIAL PRIMARY KEY, x INTEGER);
UPDATE test set x = x - 1 where id = 1;
```

There are two important elements in the above query:
- The where condition is invariant and deterministic (more on that [later](#condition)).
- The right hand side of the update statement is using the relative value instead of passing an absolute, preselected,
  value (also more on that [later](#rhs)).

## Deadlock

It is important to note that since the `UPDATE` query will implicitly use a row level lock, a deadlock
can be triggered if the transaction isolation level is set to `REPEATABLE READ` or `SERIALIZABLE`.

### Example

Let's insert two rows in the `test` table.

```sql
insert into test values (1, 0);
insert into test values (2, 0);
```

Now, to trigger the deadlock, we can open two SQL clients (we're using `psql` here):

```sql
$1> psql 
psql1> BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ
psql1> UPDATE test SET x = x + 1 WHERE id = 1; -- A lock is acquired on the row with id 1, no other transaction can update it
```

```sql
$2> psql 
psql2> BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ
psql2> UPDATE test SET x = x + 1 WHERE id = 2; -- A lock is acquired on the row with id 2, no other transaction can update it
```

```sql
psql1> UPDATE test SET x = x + 1 WHERE id = 2; -- The second session hasn't committed yet, this operation is now waiting
```

```sql
psql2> UPDATE test SET x = x + 1 WHERE id = 1; -- The first session hasn't committed yet, this operation is now waiting
```

DEADLOCK! Each session is waiting for the other one to commit or rollback.

_Note: This situation wouldn't happen in `READ UNCOMMITTED` or `READ COMMITTED` transactions._

### Solution
  
One way to prevent this is to use a deterministic ordering when multiple rows will be updated in the same transations,
in this case, if both transactions had sorted the rows by ascending id for instance, there wouldn't have been any deadlocks.

The [postgresql documentation](https://www.postgresql.org/docs/9.6/static/transaction-iso.html#XACT-READ-COMMITTED) has
a good example.

## <a id="condition"></a>Condition

As explained in the postgresql documentation, what makes the above query safe and work with a `READ COMMITTED`
transaction is the determinism of the condition used in the `WHERE` clause of the `UPDATE` query.

Let's look at un "unsafe" query:

```sql
UPDATE test set x = x + 1 WHERE x % 2 = 0;
UPDATE test set x = x + 2 WHERE x % 2 <> 0;
```

## <a id="rhs"></a>Right hand side

## Real worl example

It is common for e-commerce platform to keep track of inventories for each sku sold on the platform, a simple inventory
table could be defined as:

```sql
CREATE TABLE inventories(sku VARCHAR(3) PRIMARY KEY, quantity INTEGER);
```

### The complicated solution

__Redis__

A few years ago, when we wrote one of the first versions of our inventory system at Harry's, we didn't realize that we
could rely on SQL only to issue atomic decrements to the database, we ended up using Redis.
Redis supports out of the box increment ([`INCR`](https://redis.io/commands/incr)
& [`INCRBY`](https://redis.io/commands/incrby)) & decrement (([`DECR`](https://redis.io/commands/decr)
& [`DECRBY`](https://redis.io/commands/decrby))) operations, and being single threaded, doesn't expose any race
conditions by default.

It is definitely a valid implementation, but it adds a significant operational cost to the implementation as the
inventory data needs to be "initialized" by being copied from the DB to Redis.

The implementation can be summarized as:

- Needs to decrement inventory for sku X
- Is the value in redis
- If not, read it from the DB and set in Redis, with an explicit lock
- Decrement in redis

## Example code

I wrote a small test suite in ruby highlighting the different concepts mentioned in this article:

- The "safety" of a relative update query, even in read uncommitted transactions
- The issue with absolute updates in read uncommitted and read committed transactions
- An option using repeatable read of serializable requiring retry logic in case of serialization failures
