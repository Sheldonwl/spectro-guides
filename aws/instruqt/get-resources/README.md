# AWS Resource Report

A lightweight shell script that reports your current **EC2 vCPU quota and usage** along with **Elastic IP quotas** in any AWS region — using only read-only AWS CLI calls.

No credentials or secrets are stored in this script. It uses your existing AWS CLI configuration (environment variables, credentials file, or IAM role).

---

## Features

* Shows total, used, and remaining **EC2 vCPUs**.
* Shows total, used, and remaining **Elastic IPs**.
* Works in plain POSIX `/bin/sh` (no Bash-specific syntax).
* Uses only read-only AWS APIs.
* No dependencies beyond:

  * **AWS CLI v2**
  * Standard UNIX tools (`awk`, `date`, `printf`)

---

## Setup

1. **Clone or create the script:**

   ```bash
   git clone <your-repo-url>
   cd <your-repo-name>
   ```

   Or manually create it:

   ```bash
   nano aws_resource_report.sh
   ```

   Paste in the contents of `aws_resource_report.sh`.

2. **Make it executable:**

   ```bash
   chmod +x aws_resource_report.sh
   ```

3. **Ensure AWS CLI is configured:**

   ```bash
   aws configure
   ```

---

## Usage

Run the script with an optional region argument. If no region is provided, it defaults to `us-east-1`.

```bash
./aws_resource_report.sh
# or specify a region
./aws_resource_report.sh eu-west-1
```

### Example Output

```
==== EC2 vCPU Quota ====
Total quota : 64 vCPUs
Used        : 20 vCPUs
Remaining   : 44 vCPUs

==== Elastic IPs ====
Quota     : 5
Used      : 1
Remaining : 4

Report generated for region: us-east-1
```

---

## Security

This script:

* Stores **no AWS credentials**.
* Performs only **read-only AWS API calls** (`service-quotas`, `cloudwatch`, and `ec2 describe`).
* Is safe to commit and share in public or private Git repositories.

---

## License

**MIT License** — feel free to use, modify, and share.

