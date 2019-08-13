---
title: Converting a Rails database to Utf8mb4
author: Bryan Traywick
date: 2017-05-19 15:44 UTC
tags: rails, mysql, utf8mb4
layout: article
---

# Converting a Rails database to Utf8mb4 without downtime or data loss

Everyone loves Emojis and your users are already likely trying to use them in your app. But MySQL cheated a little and limited UTF-8 characters to 3-bytes per character. As a result your users receive an error instead of their 😀 when they try to use Emoji in your app.

Fortunately there is the utf8mb4 encoding to save the day. It is backwards compatible with utf8 and uses 4-bytes per character so that your users can use Emoji to their ❤️ delight.

But converting your database to utf8mb4, especially with a Rails app, isn't without its downsides. By default index key lengths are limited to 767 bytes which means that your `VARCHAR(255)` columns that are indexed must now be truncated to 191 characters. And every time you add a new column with `add_column ..., ..., :string` it will be created using 255 characters. Preventing you from indexing the column unless you explicitly limit it to 191 characters.

You also likely have a few large tables in your database. Converting the columns in these tables to utf8mb4 will incur a time consuming table copy which could mean downtime for your your app.

There are [several](http://blog.arkency.com/2015/05/how-to-store-emoji-in-a-rails-app-with-a-mysql-database/) [articles](https://blog.metova.com/add-emoji-support-rails-4-mysql-5-5/) and [resources](http://stackoverflow.com/questions/20465788/how-to-convert-mysql-encoding-utf8-to-utf8mb4-in-rails-project) online that discuss the [issues](https://github.com/rails/rails/issues/9855) with converting an existing database to utf8mb4. But they often ignore the problem of converting large tables, truncation of columns to 191 characters, and don't provide a complete solution to the ongoing maintenance risks of using a utf8mb4 encoded database with Rails.

Fortunately there are solutions to all of these problems. At Rails Machine we have converted several large databases to utf8mb4 with no downtime and no data loss from truncation.

## Solving the 767 byte index key limit

The InnoDB storage engine supports multiple data file formats. The default, Antelope, supports the `COMPACT` and `REDUNDANT` row formats and has the 767 byte index key limit mentioned above.

The newest file format, Barracuda, supports the newer `COMPRESSED` and `DYNAMIC` row formats and supports features such as efficient storage of off-page columns, and index key prefixes up to 3072 bytes.

To get around the 767 byte index key limit we must convert each of our tables to the Barracuda file format and enable the `innodb_large_prefix` option to allow index key prefixes longer than 768 bytes, up to 3072 bytes.

Before we can convert the tables to the Barracuda file format we must first set some configuration options. At a minimum you must set:

    innodb_file_format = Barracuda
    innodb_large_prefix = ON
    innodb_file_per_table = 1

I also recommend the following settings:

    init_connect='SET collation_connection = utf8_unicode_ci'
    init_connect='SET NAMES utf8mb4'
    innodb_file_format_max = Barracuda
    innodb_strict_mode = 1
    default_character_set = 'utf8mb4'
    character_set_server = 'utf8mb4'
    collation_server = 'utf8_unicode_ci'

Make these changes in your MySQL `my.cnf` file or using your Configuration Management system and restart MySQL.

We are now ready to change the database's default character set to utf8mb4 and convert each of the tables to the Barracuda file format.

First we set the database's default character set to utf8mb4 and collation to utf8mb4_unicode_ci:

    mysql> ALTER DATABASE <database> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

This command won't block so it is safe to run directly against the database.

Next we need to convert each table to the Barracuda file format and set the character set to utf8mb4:

    mysql> ALTER TABLE <table> ROW_FORMAT=DYNAMIC CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

By setting the table's `ROW_FORMAT` to `DYNAMIC` they will be converted to the Barracuda file format. This conversion requires a full table copy and will lock the table for the duration of the copy. For large tables this may take several minutes or even hours.

After converting the tables to the Barracuda file format and change the table's default character set to utf8mb4 the existing columns will still be using the utf8 encoding. We must run another `ALTER TABLE` command to convert the columns to the utf8mb4 character set:

    mysql> ALTER TABLE <table> MODIFY `foo` VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, MODIFY `bar` TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

Be sure to include any `NULL`/`NOT NULL` and `DEFAULT` options for each `VARCHAR`, `CHAR`, and `*TEXT` column in the table. Just like the conversion to Barracuda, this conversion will require a full table copy and will lock the table for the duration of the copy.

## Preventing downtime during the conversion

The full table copies required for the Barracuda conversion and changing the default character set for each of the existing columns is too costly to perform as a normal `ALTER TABLE` on large tables. To prevent downtime we need to be able to make these changes without locking the tables for the full duration.

This is where a tool called [pt-online-schema-change](https://www.percona.com/doc/percona-toolkit/3.0/pt-online-schema-change.html) comes in. At Rails Machine we have used pt-online-schema-change (PTOSC) for years for performing schema changes on large tables. It works by performing some clever tricks so that the amount of time that an exclusive lock must be acquired is very small. First it creates a new table with the same structure as the original table. It then runs the `ALTER TABLE` commands against this new table. These can complete very quickly since the table is empty. PTOSC then sets up triggers on the original table to replicate any `INSERT`, `UPDATE`, and `DELETE` queries in the new table. Next the rows from the original table are copied into the new table in batches. This can cause some increased load on the server so the size of the batches can be configured and PTOSC will throttle itself if CPU usage and concurrent query load gets too high in the database. Once PTOSC has finished copying the rows to the new table it briefly acquires an exclusive lock, deletes the triggers, drops the original table, and renames the new table to match the name of the original table. This typically only takes a few seconds at most.

To install PTOSC (on Ubuntu):
```
wget https://repo.percona.com/apt/percona-release_0.1-6.$(lsb_release -sc)_all.deb
sudo dpkg -i percona-release_0.1-6.$(lsb_release -sc)_all.deb
sudo apt update
sudo apt-get install percona-toolkit
```

We have written two scripts to use PTOSC to handle the Barracuda conversion and converting the existing columns to utf8mb4. These could be combined into a single script but I like to split it up for two reasons. First, I want to check the output of the Barracuda conversion to ensure there are no issues that need to be corrected before the columns are converted to utf8mb4. And second, the conversions can take a long time to run. So it's nice to have the option of running the first script overnight one day and then follow up with the utf8mb4 conversion script the next night.

The first script changes the database's default character set to utf8mb4 and converts each table to Barracuda:

```shell
#!/bin/bash

# fill these out before running:
DATABASE='your-database-name-here'
DBPASS='your-password-here'

COLLATE=utf8mb4_unicode_ci
ROW_FORMAT=DYNAMIC
THREADS_RUNNING=200

TABLES=$(echo SHOW TABLES | mysql -uroot -p$DBPASS -s $DATABASE)

echo "ALTER DATABASE $DATABASE CHARACTER SET utf8mb4 COLLATE $COLLATE" | mysql -uroot -p$DBPASS $DATABASE

for TABLE in $TABLES ; do
    echo "ALTER TABLE $TABLE ENGINE=InnoDB ROW_FORMAT=$ROW_FORMAT CHARACTER SET utf8mb4 COLLATE $COLLATE ROW_FORMAT=$ROW_FORMAT;"
    pt-online-schema-change -uroot -p$DBPASS --alter "ENGINE=InnoDB ROW_FORMAT=$ROW_FORMAT CHARACTER SET utf8mb4 COLLATE $COLLATE" D=$DATABASE,t=$TABLE --chunk-size=10k --critical-load Threads_running=$THREADS_RUNNING --set-vars innodb_lock_wait_timeout=2 --alter-foreign-keys-method=auto --execute
done
```

The second script is a [Rails runner](http://guides.rubyonrails.org/command_line.html#rails-runner) script that will scan each column in each table and generate a bash script to convert the columns to utf8mb4:

```ruby
db = ActiveRecord::Base.connection

puts '#!/bin/bash'
puts ""
puts "# change dry-run to execute when you are confident the script is ready:"
puts "COMMAND='dry-run'"
puts ""
puts "# put your db root password in here:"
puts "DBPASS='fill me out'"
puts ""

db.tables.each do |table|
  column_conversions = []
  db.columns(table).each do |column|
    case column.sql_type
      when /([a-z])*text/i
        default = (column.default.blank?) ? '' : "DEFAULT \"#{column.default}\""
        null = (column.null) ? '' : 'NOT NULL'
        column_conversions << "MODIFY \`#{column.name}\` #{column.sql_type.upcase} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci #{default} #{null}"
      when /varchar\(([0-9]+)\)/i
        sql_type = column.sql_type.upcase
        default = (column.default.blank?) ? '' : "DEFAULT \"#{column.default}\""
        null = (column.null) ? '' : 'NOT NULL'
        column_conversions << "MODIFY \`#{column.name}\` #{sql_type} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci #{default} #{null}".strip
    end
  end

  puts "# #{table}"
  if column_conversions.empty?
    puts "# NO CONVERSIONS NECESSARY FOR #{table}"
  else
    puts "pt-online-schema-change -uroot -p$DBPASS --alter '#{column_conversions.join(", ")}' D=#{db.current_database},t=#{table} --chunk-size=10k --critical-load Threads_running=200 --set-vars innodb_lock_wait_timeout=2 --alter-foreign-keys-method=auto --$COMMAND"
  end
  puts ""
end
```

Run this script with Rails runner and pipe the output to a file to: `RAILS_ENV=production bundle exec bin/rails runner create_column_conversions.rb >column_conversions.sh`. Then edit `column_conversions.sh` to add your password and run the script to perform a dry-run of the conversions to utf8mb4. If it looks good, edit the script again and change the `COMMAND` to 'execute'. Then you can run it for real.

Once the second script is finished the database will be fully converted to utf8mb4 and you can set `encoding: utf8mb4` in your `database.yml`.

## What about my development database?

The scripts above are appropriate for converting your production database to utf8mb4, but what about your development database? If you have multiple developers it may be too much to ask each one to run these scripts against their development database. We've thought of that and created a normal Rails migration to handle converting the development and test databases to utf8mb4:

```ruby
class ConvertDatabaseToUtf8mb4 < ActiveRecord::Migration[5.0]
  def db
    ActiveRecord::Base.connection
  end

  def up
    return if Rails.env.staging? or Rails.env.production?

    execute "ALTER DATABASE `#{db.current_database}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    db.tables.each do |table|
      execute "ALTER TABLE `#{table}` ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"
      execute "ALTER TABLE `#{table}` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

      db.columns(table).each do |column|
        case column.sql_type
          when /([a-z]*)text/i
            default = (column.default.blank?) ? '' : "DEFAULT '#{column.default}'"
            null = (column.null) ? '' : 'NOT NULL'
            execute "ALTER TABLE `#{table}` MODIFY `#{column.name}` #{column.sql_type.upcase} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci #{default} #{null};"
          when /varchar\(([0-9]+)\)/i
            sql_type = column.sql_type.upcase
            default = (column.default.blank?) ? '' : "DEFAULT '#{column.default}'"
            null = (column.null) ? '' : 'NOT NULL'
            execute "ALTER TABLE `#{table}` MODIFY `#{column.name}` #{sql_type} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci #{default} #{null};"
        end
      end
    end
  end
end
```

## Anything else?

After following the steps above your database will be converted to utf8mb4, and newly added columns will use utf8mb4 encoding when created using ActiveRecord's `add_column` method in a database migration. But if you are using MySQL < 5.7, or your database was created with a version before 5.7, new tables will still be created using the Antelope file format. To force new tables to be created using the Barracuda file format we must add the `ROW_FORMAT=DYNAMIC` option to ActiveRecord's `create_table` method.

Create an initializer named `config/initializers/ar_innodb_row_format.rb` and paste the following code:

```ruby
ActiveSupport.on_load :active_record do
  module ActiveRecord::ConnectionAdapters
    class AbstractMysqlAdapter
      def create_table_with_innodb_row_format(table_name, options = {})
        table_options = options.reverse_merge(:options => 'ENGINE=InnoDB ROW_FORMAT=DYNAMIC')

        create_table_without_innodb_row_format(table_name, table_options) do |td|
         yield td if block_given?
        end
      end
      alias_method_chain :create_table, :innodb_row_format
    end
  end
end
```

In newer versions of Rails or MySQL this monkey patch may not be necessary.

You now have everything you need to convert your database to utf8mb4 without downtime and no data loss from truncated columns. All of the code used in the article is available [here](https://github.com/railsmachine/utf8mb4_conversion_scripts).
