#!/bin/bash
# ──────────────────────────────────────────────────────────────
# migrate-iam-state.sh  (TEMPORARY DRAFT — not yet approved for use)
#
# Moves the shared ECS IAM resources out of an app's ECS Terraform state and
# into a new global-iam state, then (with --apply) uploads both files back to S3.
#
# OPEN ITEMS (search this file for "TODO"):
#   1. TODO: Create the test bucket (STATE_BUCKET). Needs s3:CreateBucket in the
#            assay account; read-only access cannot create it.
#   2. DONE: ASSUME_ROLE_NAME (TargetDeploymentRole) exists in the assay
#            account, is assumed by prd-docker in the app workflows, and has
#            AdministratorAccess (covers S3 read/write on STATE_BUCKET).
#   3. TODO: Upload a test ECS state that still contains the six IAM resources
#            to env:/<env>/<app>/ecs/terraform.tfstate in STATE_BUCKET.
#   4. TODO: Decide whether the West ECS state also needs its IAM removed
#            (terraform state rm). Not handled by this script.
#   5. TODO: Decide what to do if the ECS state has the DynamoDB inline policy
#            (aws_iam_role_policy.ecs_dynamodb_access). Currently: warn only.
#   6. TODO: Confirm "uat" is a real environment; remove it if not.
#   7. TODO: Before using against real state, point STATE_BUCKET /
#            AWS_ACCOUNT_NUMBER at the real backend and get approval.
#
# Usage:
#   bash scripts/migrate-iam-state.sh <env> <app_short_name> [--apply]
#
#   <env>             test | qa | uat | prod
#   <app_short_name>  e.g. mr-app1
#   --apply           actually upload to S3. Without it the script is a DRY RUN:
#                     it downloads and migrates locally but writes nothing to S3.
# ──────────────────────────────────────────────────────────────
set -euo pipefail
# NOTE: do not enable `set -x` — it would print the assumed-role credentials.




ENV_NAME="${1:-}"
APP_SHORT_NAME="${2:-}"
MODE="${3:-dry-run}"




############################################
# Configuration
############################################
AWS_ACCOUNT_NUMBER="450133580082"            # assay (sandbox) account — confirmed
AWS_REGION="us-east-2"




# TODO (open item 1): this bucket does NOT exist yet. Agreed name for the
# sandbox test bucket; someone with S3 write access must create it with this
# exact name (versioning on, public access blocked, default encryption).
STATE_BUCKET="iam-state-migration-test-450133580082"




# Confirmed (open item 2). Set to "" to use the credentials already present
# instead of assuming a role.
ASSUME_ROLE_NAME="TargetDeploymentRole"




REQUIRED_TF_VERSION="1.5.7"                  # matches the pipeline's Terraform version




ECS_KEY="env:/${ENV_NAME}/${APP_SHORT_NAME}/ecs/terraform.tfstate"
GLOBAL_KEY="env:/${ENV_NAME}/global/${APP_SHORT_NAME}/iam/terraform.tfstate"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_KEY="iam-migration-backups/${TIMESTAMP}/${ENV_NAME}/${APP_SHORT_NAME}/ecs/terraform.tfstate"




# Source address in ECS state | destination address in global-iam state
MOVES=(
  "module.ecs-infra.module.ecsservice.aws_iam_role.execution_role|module.global-iam.aws_iam_role.ecs_execution_role"
  "module.ecs-infra.module.ecsservice.aws_iam_role.task_role|module.global-iam.aws_iam_role.ecs_task_role"
  "module.ecs-infra.module.ecsservice.aws_iam_policy.policy|module.global-iam.aws_iam_policy.ecs_read_policy"
  "module.ecs-infra.module.ecsservice.aws_iam_role_policy_attachment.task_execution_role_policy_cloudwatch|module.global-iam.aws_iam_role_policy_attachment.ecs_exec_cloudwatch"
  "module.ecs-infra.module.ecsservice.aws_iam_role_policy_attachment.task_execution_role_policy_ecs|module.global-iam.aws_iam_role_policy_attachment.ecs_exec_task_execution"
  "module.ecs-infra.module.ecsservice.aws_iam_role_policy_attachment.task_task_policy_ecs|module.global-iam.aws_iam_role_policy_attachment.ecs_task_read_policy"
)
############################################
# Input validation
############################################
case "$ENV_NAME" in
  test|qa|uat|prod) ;;
  *) echo "ERROR: env must be one of: test, qa, uat, prod (got '$ENV_NAME')"; exit 1 ;;
esac




if [[ ! "$APP_SHORT_NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: app_short_name is required and may only contain lowercase letters, numbers and '-' (got '$APP_SHORT_NAME')"
  exit 1
fi




case "$MODE" in
  dry-run|--apply) ;;
  *) echo "ERROR: third argument must be --apply or omitted (got '$MODE')"; exit 1 ;;
esac




if [[ -z "$STATE_BUCKET" ]]; then
  echo "ERROR: STATE_BUCKET is not set. Update the configuration section first."
  exit 1
fi




for tool in aws terraform; do
  command -v "$tool" >/dev/null || { echo "ERROR: '$tool' is not installed"; exit 1; }
done




TF_VERSION="$(terraform version | head -n1 | sed 's/^Terraform v//')"
if [[ "$TF_VERSION" != "$REQUIRED_TF_VERSION" ]]; then
  echo "WARNING: Terraform $TF_VERSION found; pipeline uses $REQUIRED_TF_VERSION."
  echo "WARNING: State files written by a newer version may not be readable by the pipeline."
fi




echo "========================================"
echo "IAM state migration"
echo "  Mode        : $MODE"
echo "  Env         : $ENV_NAME"
echo "  App         : $APP_SHORT_NAME"
echo "  Bucket      : $STATE_BUCKET"
echo "  ECS key     : $ECS_KEY"
echo "  Global key  : $GLOBAL_KEY"
echo "========================================"




############################################
# AWS credentials
############################################
if [[ -n "$ASSUME_ROLE_NAME" ]]; then
  echo "Assuming role $ASSUME_ROLE_NAME in $AWS_ACCOUNT_NUMBER..."
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${ASSUME_ROLE_NAME}" \
      --role-session-name "iam-state-migration-${APP_SHORT_NAME}" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text
  )
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi
export AWS_DEFAULT_REGION="$AWS_REGION"




############################################
# Helpers
############################################
# Returns 0 if the object exists, 1 if it does not; exits on any other error.
object_exists() {
  local key="$1" err
  if err=$(aws s3api head-object --bucket "$STATE_BUCKET" --key "$key" 2>&1 >/dev/null); then
    return 0
  fi
  if grep -qE "Not Found|404" <<<"$err"; then
    return 1
  fi
  echo "ERROR: could not check s3://$STATE_BUCKET/$key"
  echo "$err"
  exit 1
}
WORK_DIR="$(mktemp -d)"
cd "$WORK_DIR"
echo "Working directory: $WORK_DIR"




############################################
# Preflight
############################################
# Check the bucket separately so a missing bucket or missing access isn't
# reported as "ECS state not found".
if ! aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  echo "ERROR: cannot access bucket '$STATE_BUCKET'."
  echo "ERROR: it may not exist yet (open item 1) or the role lacks access (open item 2)."
  exit 1
fi




if ! object_exists "$ECS_KEY"; then
  echo "ERROR: ECS state not found at s3://$STATE_BUCKET/$ECS_KEY"
  exit 1
fi




if object_exists "$GLOBAL_KEY"; then
  echo "ERROR: global IAM state already exists at s3://$STATE_BUCKET/$GLOBAL_KEY"
  echo "ERROR: this app/env looks already migrated. Stopping so nothing is overwritten."
  exit 1
fi




############################################
# Download
############################################
aws s3 cp "s3://$STATE_BUCKET/$ECS_KEY" original.json --only-show-errors
cp original.json original.pristine.json
echo "✓ Downloaded ECS state"




terraform state list -state=original.json > ecs-before.txt




MISSING=()
for pair in "${MOVES[@]}"; do
  src="${pair%%|*}"
  grep -qxF "$src" ecs-before.txt || MISSING+=("$src")
done




if (( ${#MISSING[@]} > 0 )); then
  echo "ERROR: these IAM resources are not in the ECS state:"
  printf '  - %s\n' "${MISSING[@]}"
  echo "ERROR: nothing was changed."
  exit 1
fi
echo "✓ All ${#MOVES[@]} IAM resources found in ECS state"




############################################
# Move
############################################
for pair in "${MOVES[@]}"; do
  src="${pair%%|*}"
  dst="${pair##*|}"
  terraform state mv -state=original.json -state-out=global.json "$src" "$dst" >/dev/null
  echo "✓ Moved $src -> $dst"
done




############################################
# Verify
############################################
terraform state list -state=original.json > ecs-after.txt
terraform state list -state=global.json > global-after.txt




LEFTOVER=$(grep -v '\.data\.' ecs-after.txt | grep -E '\.aws_iam_(role|policy|role_policy_attachment)\.' || true)
if [[ -n "$LEFTOVER" ]]; then
  echo "ERROR: ECS state still contains IAM resources:"
  echo "$LEFTOVER"
  exit 1
fi




INLINE=$(grep -E '\.aws_iam_role_policy\.' ecs-after.txt || true)
if [[ -n "$INLINE" ]]; then
  echo "WARNING: ECS state still contains an inline IAM policy (not part of this migration):"
  echo "$INLINE"
fi




GLOBAL_COUNT=$(wc -l < global-after.txt | tr -d ' ')
if [[ "$GLOBAL_COUNT" -ne "${#MOVES[@]}" ]]; then
  echo "ERROR: expected ${#MOVES[@]} resources in global state, found $GLOBAL_COUNT"
  exit 1
fi
echo "✓ Verified: ECS state has no IAM resources; global state has $GLOBAL_COUNT resources"


############################################
# Upload
############################################
if [[ "$MODE" != "--apply" ]]; then
  echo "========================================"
  echo "DRY RUN complete. Nothing was uploaded."
  echo "Re-run with --apply to upload:"
  echo "  ECS state    -> s3://$STATE_BUCKET/$ECS_KEY"
  echo "  Global state -> s3://$STATE_BUCKET/$GLOBAL_KEY"
  echo "Local files: $WORK_DIR (contains state — delete when done)"
  echo "========================================"
  exit 0
fi




aws s3 cp original.pristine.json "s3://$STATE_BUCKET/$BACKUP_KEY" --only-show-errors
echo "✓ Backup uploaded to s3://$STATE_BUCKET/$BACKUP_KEY"




# ECS first: if the global upload then fails, the roles are simply unmanaged
# (safe) rather than owned by two states (which could delete them).
aws s3 cp original.json "s3://$STATE_BUCKET/$ECS_KEY" --only-show-errors
echo "✓ Uploaded new ECS state"




if ! aws s3 cp global.json "s3://$STATE_BUCKET/$GLOBAL_KEY" --only-show-errors; then
  echo "ERROR: global state upload failed. The ECS state has already been updated."
  echo "ERROR: retry manually: aws s3 cp $WORK_DIR/global.json s3://$STATE_BUCKET/$GLOBAL_KEY"
  exit 1
fi
echo "✓ Uploaded global IAM state"




echo "========================================"
echo "Migration complete for $APP_SHORT_NAME ($ENV_NAME)"
echo "  Backup : s3://$STATE_BUCKET/$BACKUP_KEY"
echo "  Local  : $WORK_DIR (contains state — delete when done)"
echo "========================================"


how do i test the above setup in aws?

Copilot said:
