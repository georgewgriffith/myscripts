# Monitor OrientDB Performance and System Metrics

## Overview
This script (`monitor_orientdb_safe.sh`) collects and logs **critical performance metrics** from an OrientDB database while ensuring **safe resource usage** on the host machine. It outputs data in **JSON, XML, and CSV** formats for easy analysis and prevents excessive resource consumption.

## Features
- **Collects CPU, Memory, Disk IOPS, Network Traffic, and Query Performance Metrics**
- **Uses JMX to extract OrientDB-specific statistics**
- **Runs safely, preventing OOM Killer from terminating critical services**
- **Ensures available system resources before running intensive commands**
- **Logs data efficiently without overwhelming disk space**
- **Compatible with RHEL 7+ (uses standard CLI tools)**
- **Provides suggested configuration values for Azure PostgreSQL provisioning**
- **Includes guidance on provisioning Azure PostgreSQL using collected metrics**

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

### **How do I securely connect to Azure PostgreSQL?**
- Use **VNET integration** and **Private Link** for enhanced security.

### **What happens if my workload increases?**
- Consider enabling **PostgreSQL autoscaling**.
- Increase **vCPUs** or **upgrade storage tiers** dynamically.

## License
This script is open-source and can be modified as needed. Use at your own risk.

## Author
- **Developed by:** [Your Name / Team]
- **Contact:** [Your Email / GitHub]

---

This README provides **detailed instructions** for **both technical and non-technical users**, ensuring a smooth setup and execution.
