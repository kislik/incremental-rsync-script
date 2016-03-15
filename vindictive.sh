#!/bin/bash
PATH=/sbin:/usr/sbin:/bin:/usr/bin

if [ "$1" == "" ]; then
    echo "Arguments not detected. Try running the script with the argument \"--help\" or \"-h\""
    exit 0
fi

print_usage () {
echo "Enter several arguments!"
echo -e 'Where:
 -h (necessarily) remote host;
 -u (necessarily) remote user;
 -p (necessarily) remote port;
 -r (necessarily) remote dir;
 -f (necessarily) current full backup dir;
 -i (necessarily) current incremental backup dir;
 -o (not necessarily) frequense create full backup;
 -l (not necessarily) rsync log FILE (FILE!!!) (by default, the log is in the directory with a full backup);
 -n (not necessarily) service-name in nagios;
 -h (not necessarily) this help message }=-(

example:  ./vindictive.sh -h 192.168.2.2 -u backup -p 22 -r /home/data/some_dir -f /home/backup/some_dir/full -i /home/backup/some_dir/incremental '
}

checkargs () {
if [[ $OPTARG =~ ^-[h/u/p/r/f/i/o/l/n]$ ]];then
    echo "Unknown argument $OPTARG for option $OPTIONS!"
    exit "$STATE_UNKNOWN"
fi
}

while getopts "h:u:p:r:f:i:o:l:n:" OPTIONS
do
    case $OPTIONS in
        h) checkargs #host
            REMOTE_HOST=`echo $OPTARG | grep -v "^-"`
            ;;
        u) checkargs #user
            REMOTE_USER=`echo $OPTARG | grep -v "^-"`
            ;;
        p) checkargs #port
            SSH_PORT=`echo $OPTARG | grep -v "^-"`
            ;;
        r) checkargs #remote dir
            REMOTE_DIRS=`echo $OPTARG | grep -v "^-"`
            ;;
        f) checkargs #current full backup dir
            FULL_BACKUP_DIR=`echo $OPTARG | grep -v "^-"`
            ;;
        i) checkargs #current incremental backup dir
            INCREMENTAL_BACKUP_DIR=`echo $OPTARG | grep -v "^-"`
            ;;
        o) checkargs #frequense create full backup
            FREQUENCY_FULL_BACKUP=`echo $OPTARG | grep -v "^-"`
            ;;
        l) checkargs #log file
            LOG=`echo $OPTARG | grep -v "^-"`
            ;;
        n) checkargs #service-name in nagios
            NAGIOS_SERVICE=`echo $OPTARG | grep -v "^-"`
            ;;
        *) print_usage
            exit 0
            ;;
    esac
done

if [[ -z $LOG ]]; then
    LOG="$FULL_BACKUP_DIR/rsync.log"
fi

if [[ ! -f "$LOG" ]]; then
    mkdir -p `dirname $LOG`
    touch "$LOG"
    echo "log file was created - $LOG"
fi

exec 8>&1
exec >> $LOG
echo `date`
echo "============================="

# Nagios
NAGIOS_HOST='193.232.121.174'
NAGIOS_PORT='5667'

report_error() {
    # error - nagios msg
    /usr/local/bin/nsca_send -n $NAGIOS_HOST -p $NAGIOS_PORT -h `cat /etc/hostname` -s $NAGIOS_SERVICE -c 2 -o "you can try to find the error in the log $LOG"
}

report_ok() {
    # ok - nagios msg
    /usr/local/bin/nsca_send -n $NAGIOS_HOST -p $NAGIOS_PORT -h `cat /etc/hostname` -s $NAGIOS_SERVICE -c 0 -o "OK"
}

# Do not change the date format
DATE=`date +%Y%m%d_%H%M%S`

# Rsync
RSYNC="rsync --recursive --verbose --archive --numeric-ids --8-bit-output --inplace --relative"
#The syntax for requesting multiple files from a remote host is done
#    rsync -av host:file2 :file2 host:file{3,4} /dest/
#    rsync -av host::modname/file{1,2} host::modname/file3 /dest/
#    rsync -av host::modname/file1 ::modname/file{3,4}
if [[ -z $FREQUENCY_FULL_BACKUP ]]; then
    FREQUENCY_FULL_BACKUP="28"
fi

# To check an existing directory
if [[ ! -d "$FULL_BACKUP_DIR" ]]; then
    mkdir -p $FULL_BACKUP_DIR
    echo "directory was created - $FULL_BACKUP_DIR"
fi


# Full backup
# The frequency of creating a full backup
FULL_BACKUP_NAME=`ls -1 $FULL_BACKUP_DIR |perl -ne 'print if /^\d{8}_\d{6}$/' |sort -n |tail -n1`
LAST_FULL_BACKUP=`echo $FULL_BACKUP_NAME |sed 's/^\(........\).*/\1/'`
if [[ -z "$LAST_FULL_BACKUP" ]]; then
    echo "It seems this is your first full backup $REMOTE_DIRS"
    echo -e "\n"

    $RSYNC -e "ssh -p $SSH_PORT" $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIRS $FULL_BACKUP_DIR/$DATE

    if [ $? != 0 ]; then
        report_error "Full backup error - rsync exit code = $?"
        exit 1
    else
       report_ok "Full backup success - rsync exit code = $?"
       exit 0
    fi
fi

CURRENT_DAY=`date +%Y%m%d`
DAYS_AGO_FULL_BACKUP=$(( $CURRENT_DAY - $LAST_FULL_BACKUP ))

if (("$DAYS_AGO_FULL_BACKUP" >= "$FREQUENCY_FULL_BACKUP")); then
    $RSYNC -e "ssh -p $SSH_PORT" $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIRS $FULL_BACKUP_DIR/$DATE
    echo "create full backup"
else
    echo "Last full backup was created in $LAST_FULL_BACKUP, the next full backup will be after $(( $FREQUENCY_FULL_BACKUP - $DAYS_AGO_FULL_BACKUP )) days"
fi


# Incremental backup
if [[ ! -d "$INCREMENTAL_BACKUP_DIR/$DATE" ]]; then
    mkdir -p $INCREMENTAL_BACKUP_DIR/$DATE
    echo "directory was created - $INCREMENTAL_BACKUP_DIR/$DATE"
fi

$RSYNC  -e "ssh -p $SSH_PORT" --only-write-batch=$INCREMENTAL_BACKUP_DIR/$DATE/deploy_me  $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIRS $FULL_BACKUP_DIR/$FULL_BACKUP_NAME

if [ $? != 0 ]; then
    report_error "Incremental backup error - rsync exit code = $?"
    exit 1
else
   report_ok "Incremental backup success - rsync exit code = $?"
   exit 0
fi


# Delete old backup
BACKUP_DIRS="$FULL_BACKUP_DIR $INCREMENTAL_BACKUP_DIR"
CURRENT_TIMESTAMP=`date +%s`

for BACKUP_DIR in $BACKUP_DIRS; do

    GET_DIRS=`ls -1 $BACKUP_DIR`

    if [[ $BACKUP_DIR == $INCREMENTAL_BACKUP_DIR ]]; then
       DAYS_TO_SAVE="32"
       else
       DAYS_TO_SAVE="93"
    fi

    for GET_DIR in $GET_DIRS; do
        DIR_DATE="echo "$GET_DIR" |head -c8 |xargs -i{} date -d {}  +'%F %s' |awk '{print \$2}'"
        GET_DIR_DATE=`eval $DIR_DATE`
        DAYS_TO_SAVE_IN_SECONDS=$[$DAYS_TO_SAVE*24*60*60]
        GET_AGE_BACKUP=$[$CURRENT_TIMESTAMP-$GET_DIR_DATE]

            if (( "$GET_AGE_BACKUP" > "$DAYS_TO_SAVE_IN_SECONDS" )); then
                echo "delete $BACKUP_DIR/$GET_DIR"
                rm -r $BACKUP_DIR/$GET_DIR

            fi
    done

done


echo -e "\n\n"
exec 1>&8 8>&-
exit 0
