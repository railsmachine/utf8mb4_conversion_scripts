db = ActiveRecord::Base.connection

puts '#!/bin/bash'
puts ""
puts "COMMAND='dry-run'"
puts ""
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
    puts "pt-online-schema-change -uroot --alter '#{column_conversions.join(", ")}' D=#{db.current_database},t=#{table} --chunk-size=10k --critical-load Threads_running=200 --set-vars innodb_lock_wait_timeout=2 --alter-foreign-keys-method=auto --$COMMAND"
  end
  puts ""
end
