require 'pg'
require 'sqlite3'
require 'mysql2'
require 'sequel'

t0 = Time.now
threads = []
5.times do |i|
  threads << Thread.new do
    # db = Sequel.connect('postgres://pierre:@localhost:5432/pierre')
    # db = Sequel.connect('mysql://root:@localhost:3306/test')
    db = Sequel.connect('sqlite://test.db')
    # test = db[:test]
    100.times do
      # values : uncommited / committed / repeatable / serializable
      done = false
      # while !done
        begin
          db.transaction(isolation: :uncommitted) do
            # val = test.where(id: 1).for_update.first[:value]
            val = nil
            # db["select value from test where id = 1 for update;"].each do |row|
            #   val = row[:value]
            # end
            # db.run("update test set value = #{val} + 1 where id = 1;")
            # test.where(id: 1).update(value: val + 1)
            # if true || (rand 2) == 0
              db.run("update inventories set quantity = quantity + 1 where sku = 'ABC';")
            #   db.run("update test set value = value + 1 where id = 2;")
            # else
            #   db.run("update test set value = value + 1 where id = 2;")
            #   db.run("update test set value = value + 1 where id = 1;")
            # end
          end
          done = true
        rescue StandardError => e
          p "retrying because of #{e}"
        end
      # end
    end
  end
end
threads.map(&:join)
p Time.now - t0

