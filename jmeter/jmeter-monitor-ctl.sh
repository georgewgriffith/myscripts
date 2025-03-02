#!/bin/bash

case "$1" in
    status)
        systemctl status jmeter-monitor
        [ -f /var/run/jmeter-monitor.status ] && cat /var/run/jmeter-monitor.status
        ;;
    start)
        systemctl start jmeter-monitor
        ;;
    stop)
        systemctl stop jmeter-monitor
        ;;
    restart)
        systemctl restart jmeter-monitor
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
