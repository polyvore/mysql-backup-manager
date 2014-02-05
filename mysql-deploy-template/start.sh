#!/bin/bash
MYSQL_HOME=DEPLOYDIR nohup /usr/sbin/mysqld --basedir=/usr --datadir=DEPLOYDIR/data --plugin-dir=/usr/lib/mysql/plugin --user=mysql --log-error=DEPLOYDIR/logs/mysql-error.log --open-files-limit=65535 --pid-file=DEPLOYDIR/run/mysql.pid --socket=DEPLOYDIR/run/mysql.sock &

