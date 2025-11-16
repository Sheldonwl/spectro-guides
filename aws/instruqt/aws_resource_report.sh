#!/bin/sh
#
# aws_resource_report.sh
#
# Description:
#   Generates a quick account-wide summary of EC2 compute (vCPU)
#   and basic networking resources (Elastic IPs) using read-only
#   AWS CLI commands.
#
#   ✅ No credentials or secrets are stored in this file.
#   It uses your existing AWS CLI authentication (env vars,
#   IAM role, or credentials file).
#
# -----------------------------------------------------------------------------
# How to create and use this script
# -----------------------------------------------------------------------------
# 1. Create the file:
#      nano aws_resource_report.sh
#         (or use vim, vi, cat > aws_resource_report.sh, etc.)
#
# 2. Paste this entire script into the file and save it.
#
# 3. Make it executable:
#      chmod +x aws_resource_report.sh
#
# 4. Run it (region is optional, defaults to us-east-1):
#      ./aws_resource_report.sh
#      ./aws_resource_report.sh eu-west-1
#
# -----------------------------------------------------------------------------
# Requirements:
#   - AWS CLI v2 installed and configured (`aws configure`)
#   - Standard UNIX tools: awk, date, printf
# -----------------------------------------------------------------------------

REGION="${1:-us-east-1}"

# Disable AWS CLI pager to show raw output.
aws configure set cli_pager ""

###############################################################################
# EC2 vCPU quota & usage
###############################################################################
TOTAL=$(aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region "$REGION" \
  --query 'Quota.Value' --output text)

USED=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Usage \
  --metric-name ResourceCount \
  --dimensions Name=Service,Value=EC2 Name=Type,Value=Resource \
               Name=Class,Value=Standard/OnDemand Name=Resource,Value=vCPU \
  --statistics Maximum \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --region "$REGION" \
  --query 'Datapoints[0].Maximum' --output text)

# Normalize "None" or empty values
if [ -z "$USED" ] || [ "$USED" = "None" ]; then USED=0; fi

echo "==== EC2 vCPU Quota ===="
echo "Total quota : $TOTAL vCPUs"
echo "Used        : $USED vCPUs"
awk "BEGIN { printf \"Remaining   : %.0f vCPUs\n\", ($TOTAL+0) - ($USED+0) }"
echo

###############################################################################
# Elastic IPs (quota code: L-0263D0A3)
###############################################################################
EIP_QUOTA=$(aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-0263D0A3 \
  --region "$REGION" \
  --query 'Quota.Value' --output text)

EIP_USED=$(aws ec2 describe-addresses \
  --region "$REGION" \
  --query 'length(Addresses)' --output text)

if [ -z "$EIP_QUOTA" ] || [ "$EIP_QUOTA" = "None" ]; then EIP_QUOTA=0; fi
if [ -z "$EIP_USED" ]  || [ "$EIP_USED"  = "None" ]; then EIP_USED=0; fi

echo "==== Elastic IPs ===="
echo "Quota     : $EIP_QUOTA"
echo "Used      : $EIP_USED"
awk "BEGIN { printf \"Remaining : %.0f\n\", ($EIP_QUOTA+0) - ($EIP_USED+0) }"
echo

###############################################################################
# End of report
###############################################################################
echo "Report generated for region: $REGION"
