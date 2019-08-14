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
