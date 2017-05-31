require 'minitest/autorun'
require 'pg'
require 'mysql2'
require 'sequel'

def get_db(database_name)
  case database_name
  when :pg
    Sequel.connect('postgres://pierre:@localhost:5432/pierre')
  when :mysql
    Sequel.connect('mysql2://root:@localhost:3306/test')
end

def execute(database_name, isolation_level)
  main_db = get_db(database_name)
  main_db["update inventories set quantity = 0 where sku = 'ABC';"].first
  t0 = Time.now
  threads = []
  5.times do |i|
    threads << Thread.new do
      db = get_db(database_name)
      100.times do
        done = false
        while !done
          begin
            db.transaction(isolation: isolation_level) do
              val = nil
              db.run("update inventories set quantity = quantity + 1 where sku = 'ABC';")
            end
            done = true
          rescue StandardError => e
            # Simply retrying until the transaction commits successfully, this
            # is only useful for REPEATABLE READ and SERIALIZABLE isolation
            # levels
          end
        end
      end
    end
  end
  threads.map(&:join)
  puts "Database: #{database_name} with #{isolation_level} took: #{Time.now - t0}"
  main_db["select * from inventories where sku = 'ABC';"].first[:quantity]
end

describe "Isolation levels" do
  describe "with pg" do
    # Local setup:
    # $> psql
    # $> CREATE TABLE inventories(sku VARCHAR(3) PRIMARY KEY, quantity INTEGER);
    # $> insert into inventories values ('ABC', 0);
    # $> insert into inventories values ('DEF', 0);
    describe "read uncommitted" do
      it "works" do
        execute(:pg, :uncommitted).must_equal 500
      end
    end

    describe "read committed" do
      it "works" do
        execute(:pg, :committed).must_equal 500
      end
    end

    describe "repeatable read" do
      it "works" do
        execute(:pg, :repeatable).must_equal 500
      end
    end

    describe "serializable" do
      it "works" do
        execute(:pg, :serializable).must_equal 500
      end
    end
  end

  describe "with mysql" do
    # Local setup:
    # $> mysql
    # $> CREATE DATABASE test;
    # $> CREATE TABLE inventories(sku VARCHAR(3) PRIMARY KEY, quantity INTEGER);
    # $> INSERT INTO inventories VALUES ('ABC', 0);
    # $> INSERT INTO inventories VALUES ('DEF', 0);
    describe "read uncommitted" do
      it "works" do
        execute(:mysql, :uncommitted).must_equal 500
      end
    end

    describe "read committed" do
      it "works" do
        execute(:mysql, :committed).must_equal 500
      end
    end

    describe "repeatable read" do
      it "works" do
        execute(:mysql, :repeatable).must_equal 500
      end
    end

    describe "serializable" do
      it "works" do
        execute(:mysql, :serializable).must_equal 500
      end
    end
  end
end
