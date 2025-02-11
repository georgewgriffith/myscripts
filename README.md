# Monitor OrientDB Performance and System Metrics

## Overview
This script (`monitor_orientdb.sh`) collects and logs **critical performance metrics** from an OrientDB database while ensuring **safe resource usage** on the host machine. It outputs data in **JSON, XML, and CSV** formats for easy analysis and prevents excessive resource consumption.

## Features
- **Collects CPU, Memory, Disk IOPS, Network Traffic, and Query Performance Metrics**
- **Uses JMX to extract OrientDB-specific statistics**
- **Runs safely, preventing OOM Killer from terminating critical services**
- **Ensures available system resources before running intensive commands**
- **Logs data efficiently without overwhelming disk space**
- **Compatible with RHEL 7+ (uses standard CLI tools)**
- **Provides suggested configuration values for Azure PostgreSQL provisioning**
- **Includes guidance on provisioning Azure PostgreSQL using collected metrics**

## Customization Options

The script allows users to **customize monitoring parameters** using command-line arguments.

### **Available Options**
| Option | Description | Default Value |
|--------|-------------|--------------|
| `-d <device>` | Specify the disk device to monitor | `sda` |
| `-n <interface>` | Specify the network interface to monitor | `eth0` |
| `-i <seconds>` | Set the monitoring interval (in seconds) | `60` |
| `-t <hours>` | Set the total duration (in hours) | `6` |
| `-o <directory>` | Set the output directory for metrics logs | `$HOME/orientdb_metrics` |

### **Usage Example**
```bash
./monitor_orientdb.sh -d nvme0n1 -n ens160 -i 30 -t 12 -o /var/log/orientdb_metrics

## Collected Metrics
### **System Performance Metrics**
| Metric | Description | Suggested Azure PostgreSQL Configuration |
|--------|-------------|--------------------------------|
| **CPU Usage** | Tracks user and system CPU usage (%) | Configure based on observed CPU usage (e.g., General Purpose tier with vCores matching max CPU avg) |
| **Memory Usage** | Monitors available and used RAM | Match max observed memory usage, selecting appropriate PostgreSQL SKU |
| **Disk Read/Write** | Measures IOPS using `iostat` and `iotop` | Use observed IOPS to select correct storage tier (e.g., 1250 IOPS -> P20 disk) |
| **Network Traffic** | Captures network RX/TX using `sar` | Use bandwidth requirements to determine Azure PostgreSQL network configurations |
| **File Descriptors** | Tracks open files using `lsof` | Tune PostgreSQL `max_connections` based on connection usage |
| **Suggested vCPUs** | Determines appropriate vCPU count based on system load | Select an Azure PostgreSQL SKU that aligns with peak CPU usage |
| **Suggested Network Throughput** | Tracks required network performance | Ensure Azure PostgreSQL networking configuration supports observed throughput |

### **OrientDB-Specific Metrics (via JMX)**
| Metric | Description | Suggested Azure PostgreSQL Configuration |
|--------|-------------|--------------------------------|
| **Query Cache Hit Ratio** | Measures how efficiently OrientDB caches queries | Optimize PostgreSQL `shared_buffers` to maximize cache efficiency |
| **Garbage Collection Count** | Tracks how often Java GC runs | Not directly applicable; ensure PostgreSQL memory settings align with expected workload |
| **Heap Memory Usage** | Monitors Java heap consumption | Allocate memory accordingly in Azure PostgreSQL sizing |
| **Active Transactions** | Counts current database transactions | Adjust `max_connections` and `work_mem` for expected concurrency |
| **Recommended PostgreSQL Extensions** | Suggests extensions to enhance PostgreSQL performance | `pg_stat_statements`, `pg_cron`, `pg_partman` for query monitoring, scheduling, and partitioning |

## Using Collected Metrics to Provision Azure PostgreSQL
The following command provisions an Azure PostgreSQL instance based on the collected metrics:
```bash
az postgres flexible-server create \
    --name my-postgres-server \
    --resource-group my-resource-group \
    --location eastus \
    --sku-name GP_Standard_D4s_v3 \
    --storage-size 256 \
    --tier GeneralPurpose \
    --max-connections 500 \
    --public-access none
```
Adjust `--sku-name`, `--storage-size`, and `--max-connections` according to the observed metrics.

## FAQ
### **What if IOPS is too low on Azure PostgreSQL?**
- Move to a **higher IOPS storage tier**, such as **P30 or higher disks**.

### **What if queries are slow?**
- Enable **`pg_stat_statements`** for query analysis.
- Optimize **indexes** and tune `work_mem`.

## Disclaimer

### Use at Your Own Risk

This script and the accompanying documentation are provided as is, without warranties or guarantees of any kind. The author(s) disclaim all liability for any loss, damage, disruption, or other issues arising directly or indirectly from the use of this script.

### No Guarantee of Accuracy

While efforts have been made to ensure the accuracy of the provided information, the author(s) do not guarantee that the suggested configurations will be suitable for your specific workload or environment. Users must validate all settings before applying them to production systems.

### No Liability for System Issues

By using this script, you agree that the author(s) are not responsible for:

- Unexpected system crashes, failures, or downtime.
- Data loss, corruption, or security vulnerabilities.
- Increased costs due to misconfiguration or over-provisioning.
- Regulatory or compliance violations caused by incorrect settings.

### Modifications and Redistribution

You are free to modify and distribute this script, but you must acknowledge the risks and test configurations before applying them in any critical environment. Users assume full responsibility for any modifications made.

## License
This script is open-source and can be modified as needed. Use at your own risk.
