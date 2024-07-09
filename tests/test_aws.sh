#!/usr/bin/env bats

source ./tests/setup.sh
source ./tests/util.sh
source ./tests/util_aws.sh
source ./tests/util_bucket_create.sh
source ./tests/util_file.sh
source ./tests/util_users.sh
source ./tests/test_common.sh
source ./tests/commands/copy_object.sh
source ./tests/commands/delete_bucket_policy.sh
source ./tests/commands/delete_object_tagging.sh
source ./tests/commands/get_bucket_acl.sh
source ./tests/commands/get_bucket_policy.sh
source ./tests/commands/get_bucket_versioning.sh
source ./tests/commands/get_object.sh
source ./tests/commands/get_object_attributes.sh
source ./tests/commands/get_object_legal_hold.sh
source ./tests/commands/get_object_lock_configuration.sh
source ./tests/commands/get_object_retention.sh
source ./tests/commands/get_object_tagging.sh
source ./tests/commands/list_multipart_uploads.sh
source ./tests/commands/list_object_versions.sh
source ./tests/commands/put_bucket_acl.sh
source ./tests/commands/put_bucket_policy.sh
source ./tests/commands/put_bucket_versioning.sh
source ./tests/commands/put_object.sh
source ./tests/commands/put_object_legal_hold.sh
source ./tests/commands/put_object_retention.sh
source ./tests/commands/select_object_content.sh

export RUN_USERS=true

# abort-multipart-upload
@test "test_abort_multipart_upload" {
  local bucket_file="bucket-file"

  create_test_files "$bucket_file" || fail "error creating test files"
  dd if=/dev/urandom of="$test_file_folder/$bucket_file" bs=5M count=1 || fail "error creating test file"

  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "Failed to create bucket '$BUCKET_ONE_NAME'"

  run_then_abort_multipart_upload "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 || fail "abort failed"

  if object_exists "aws" "$BUCKET_ONE_NAME" "$bucket_file"; then
    fail "Upload file exists after abort"
  fi

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

# complete-multipart-upload
@test "test_complete_multipart_upload" {
  local bucket_file="bucket-file"

  create_test_files "$bucket_file" || fail "error creating test files"
  dd if=/dev/urandom of="$test_file_folder/$bucket_file" bs=5M count=1 || fail "error creating test file"

  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "failed to create bucket '$BUCKET_ONE_NAME'"

  multipart_upload "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 || fail "error performing multipart upload"

  download_and_compare_file "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder/$bucket_file-copy" || fail "error downloading and comparing file"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

# copy-object
@test "test_copy_object" {
  test_common_copy_object "s3api"
}

@test "test_copy_object_empty" {
  copy_object_empty || local result=$?
  [[ result -eq 0 ]] || fail "copy objects with no parameters test failure"
}

# create-bucket
@test "test_create_delete_bucket_aws" {
  test_common_create_delete_bucket "aws"
}

# create-multipart-upload
@test "test_create_multipart_upload_properties" {
  local bucket_file="bucket-file"

  local expected_content_type="application/zip"
  local expected_meta_key="testKey"
  local expected_meta_val="testValue"
  local expected_hold_status="ON"
  local expected_retention_mode="GOVERNANCE"
  local expected_tag_key="TestTag"
  local expected_tag_val="TestTagVal"
  local five_seconds_later

  os_name="$(uname)"
  if [[ "$os_name" == "Darwin" ]]; then
    now=$(date -u +"%Y-%m-%dT%H:%M:%S")
    later=$(date -j -v +15S -f "%Y-%m-%dT%H:%M:%S" "$now" +"%Y-%m-%dT%H:%M:%S")
  else
    now=$(date +"%Y-%m-%dT%H:%M:%S")
    later=$(date -d "$now 15 seconds" +"%Y-%m-%dT%H:%M:%S")
  fi

  create_test_files "$bucket_file" || fail "error creating test file"
  dd if=/dev/urandom of="$test_file_folder/$bucket_file" bs=5M count=1 || fail "error creating test file"

  delete_bucket_or_contents_if_exists "s3api" "$BUCKET_ONE_NAME" || fail "error deleting bucket, or checking for existence"
  # in static bucket config, bucket will still exist
  bucket_exists "s3api" "$BUCKET_ONE_NAME" || local exists_result=$?
  [[ $exists_result -ne 2 ]] || fail "error checking for bucket existence"
  if [[ $exists_result -eq 1 ]]; then
    create_bucket_object_lock_enabled "$BUCKET_ONE_NAME" || fail "error creating bucket"
  fi

  log 5 "LATER: $later"
  multipart_upload_with_params "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 \
    "$expected_content_type" \
    "{\"$expected_meta_key\": \"$expected_meta_val\"}" \
    "$expected_hold_status" \
    "$expected_retention_mode" \
    "$later" \
    "$expected_tag_key=$expected_tag_val" || fail "error performing multipart upload"

  head_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error getting metadata"
  raw_metadata=$(echo "$metadata" | grep -v "InsecureRequestWarning")
  log 5 "raw metadata: $raw_metadata"

  content_type=$(echo "$raw_metadata" | jq -r ".ContentType")
  [[ $content_type == "$expected_content_type" ]] || fail "content type mismatch ($content_type, $expected_content_type)"
  meta_val=$(echo "$raw_metadata" | jq -r ".Metadata.$expected_meta_key")
  [[ $meta_val == "$expected_meta_val" ]] || fail "metadata val mismatch ($meta_val, $expected_meta_val)"
  hold_status=$(echo "$raw_metadata" | jq -r ".ObjectLockLegalHoldStatus")
  [[ $hold_status == "$expected_hold_status" ]] || fail "hold status mismatch ($hold_status, $expected_hold_status)"
  retention_mode=$(echo "$raw_metadata" | jq -r ".ObjectLockMode")
  [[ $retention_mode == "$expected_retention_mode" ]] || fail "retention mode mismatch ($retention_mode, $expected_retention_mode)"
  retain_until_date=$(echo "$raw_metadata" | jq -r ".ObjectLockRetainUntilDate")
  [[ $retain_until_date == "$later"* ]] || fail "retention date mismatch ($retain_until_date, $five_seconds_later)"

  get_object_tagging "aws" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error getting tagging"
  log 5 "tags: $tags"
  tag_key=$(echo "$tags" | jq -r ".TagSet[0].Key")
  [[ $tag_key == "$expected_tag_key" ]] || fail "tag mismatch ($tag_key, $expected_tag_key)"
  tag_val=$(echo "$tags" | jq -r ".TagSet[0].Value")
  [[ $tag_val == "$expected_tag_val" ]] || fail "tag mismatch ($tag_val, $expected_tag_val)"

  put_object_legal_hold "$BUCKET_ONE_NAME" "$bucket_file" "OFF" || fail "error disabling legal hold"
  head_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error getting metadata"

  get_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder/$bucket_file-copy" || fail "error getting object"
  compare_files "$test_file_folder/$bucket_file" "$test_file_folder/$bucket_file-copy" || fail "files not equal"

  sleep 15

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}


# delete-bucket - test_create_delete_bucket_aws

# delete-bucket-policy
@test "test_get_put_delete_bucket_policy" {
  test_common_get_put_delete_bucket_policy "aws"
}

# delete-bucket-tagging
@test "test-set-get-delete-bucket-tags" {
  test_common_set_get_delete_bucket_tags "aws"
}

# delete-object - tested with bucket cleanup before or after tests

# delete-object-tagging
@test "test_delete_object_tagging" {
  test_common_delete_object_tagging "aws"
}

# delete-objects
@test "test_delete_objects" {
  local object_one="test-file-one"
  local object_two="test-file-two"

  create_test_files "$object_one" "$object_two" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local result_one=$?
  [[ $result_one -eq 0 ]] || fail "Error creating bucket"

  put_object "s3api" "$test_file_folder"/"$object_one" "$BUCKET_ONE_NAME" "$object_one" || local result_two=$?
  [[ $result_two -eq 0 ]] || fail "Error adding object one"
  put_object "s3api" "$test_file_folder"/"$object_two" "$BUCKET_ONE_NAME" "$object_two" || local result_three=$?
  [[ $result_three -eq 0 ]] || fail "Error adding object two"

  error=$(aws --no-verify-ssl s3api delete-objects --bucket "$BUCKET_ONE_NAME" --delete '{
    "Objects": [
      {"Key": "test-file-one"},
      {"Key": "test-file-two"}
    ]
  }') || local result=$?
  [[ $result -eq 0 ]] || fail "Error deleting objects: $error"

  object_exists "aws" "$BUCKET_ONE_NAME" "$object_one" || local exists_one=$?
  [[ $exists_one -eq 1 ]] || fail "Object one not deleted"
  object_exists "aws" "$BUCKET_ONE_NAME" "$object_two" || local exists_two=$?
  [[ $exists_two -eq 1 ]] || fail "Object two not deleted"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$object_one" "$object_two"
}

# get-bucket-acl
@test "test_get_bucket_acl" {
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating bucket"

  get_bucket_acl "s3api" "$BUCKET_ONE_NAME" || local result=$?
  [[ $result -eq 0 ]] || fail "Error retrieving acl"

  id=$(echo "$acl" | grep -v "InsecureRequestWarning" | jq '.Owner.ID')
  [[ $id == '"'"$AWS_ACCESS_KEY_ID"'"' ]] || fail "Acl mismatch"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

# get-bucket-location
@test "test_get_bucket_location" {
  test_common_get_bucket_location "aws"
}

# get-bucket-policy - test_get_put_delete_bucket_policy

# get-bucket-tagging - test_set_get_delete_bucket_tags

# get-object
@test "test_get_object_full_range" {
  bucket_file="bucket_file"

  create_test_files "$bucket_file" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  echo -n "0123456789" > "$test_file_folder/$bucket_file"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || local setup_result=$?
  [[ $setup_result -eq 0 ]] || fail "error setting up bucket"
  put_object "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error putting object"
  get_object_with_range "$BUCKET_ONE_NAME" "$bucket_file" "bytes=9-15" "$test_file_folder/$bucket_file-range" || fail "error getting range"
  [[ "$(cat "$test_file_folder/$bucket_file-range")" == "9" ]] || fail "byte range not copied properly"
}

@test "test_get_object_invalid_range" {
  bucket_file="bucket_file"

  create_test_files "$bucket_file" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || local setup_result=$?
  [[ $setup_result -eq 0 ]] || fail "error setting up bucket"
  put_object "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error putting object"
  get_object_with_range "$BUCKET_ONE_NAME" "$bucket_file" "bytes=0-0" "$test_file_folder/$bucket_file-range" || local get_result=$?
  [[ $get_result -ne 0 ]] || fail "Get object with zero range returned no error"
}

@test "test_put_object" {
  bucket_file="bucket_file"

  create_test_files "$bucket_file" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || local setup_result=$?
  [[ $setup_result -eq 0 ]] || fail "error setting up bucket"
  setup_bucket "s3api" "$BUCKET_TWO_NAME" || local setup_result_two=$?
  [[ $setup_result_two -eq 0 ]] || fail "Bucket two setup error"
  put_object "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" || local copy_result=$?
  [[ $copy_result -eq 0 ]] || fail "Failed to add object to bucket"
  copy_error=$(aws --no-verify-ssl s3api copy-object --copy-source "$BUCKET_ONE_NAME/$bucket_file" --key "$bucket_file" --bucket "$BUCKET_TWO_NAME" 2>&1) || local copy_result=$?
  [[ $copy_result -eq 0 ]] || fail "Error copying file: $copy_error"
  copy_file "s3://$BUCKET_TWO_NAME/$bucket_file" "$test_file_folder/${bucket_file}_copy" || local copy_result=$?
  [[ $copy_result -eq 0 ]] || fail "Failed to add object to bucket"
  compare_files "$test_file_folder/$bucket_file" "$test_file_folder/${bucket_file}_copy" || local compare_result=$?
  [[ $compare_result -eq 0 ]] || file "files don't match"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_bucket_or_contents "aws" "$BUCKET_TWO_NAME"
  delete_test_files "$bucket_file"
}

@test "test_create_bucket_invalid_name" {
  if [[ $RECREATE_BUCKETS != "true" ]]; then
    return
  fi

  create_bucket_invalid_name "aws" || local create_result=$?
  [[ $create_result -eq 0 ]] || fail "Invalid name test failed"

  [[ "$bucket_create_error" == *"Invalid bucket name "* ]] || fail "unexpected error:  $bucket_create_error"
}

# test adding and removing an object on versitygw
@test "test_put_object_with_data" {
  test_common_put_object_with_data "aws"
}

@test "test_put_object_no_data" {
  test_common_put_object_no_data "aws"
}

# test listing buckets on versitygw
@test "test_list_buckets" {
  test_common_list_buckets "s3api"
}

# test listing a bucket's objects on versitygw
@test "test_list_objects" {
  test_common_list_objects "aws"
}


@test "test_get_object_attributes" {
  bucket_file="bucket_file"

  create_test_files "$bucket_file" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating bucket"
  put_object "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" || local copy_result=$?
  [[ $copy_result -eq 0 ]] || fail "Failed to add object to bucket"
  get_object_attributes "$BUCKET_ONE_NAME" "$bucket_file" || local get_result=$?
  [[ $get_result -eq 0 ]] || fail "failed to get object attributes"
  # shellcheck disable=SC2154
  if echo "$attributes" | jq -e 'has("ObjectSize")'; then
    object_size=$(echo "$attributes" | jq ".ObjectSize")
    [[ $object_size == 0 ]] || fail "Incorrect object size: $object_size"
  else
    fail "ObjectSize parameter missing: $attributes"
  fi
  delete_bucket_or_contents "s3api" "$BUCKET_ONE_NAME"
}

#@test "test_get_put_object_legal_hold" {
#  # bucket must be created with lock for legal hold
#  if [[ $RECREATE_BUCKETS == false ]]; then
#    return
#  fi
#
#  bucket_file="bucket_file"
#  username="ABCDEFG"
#  password="HIJKLMN"
#
#  legal_hold_retention_setup "$username" "$password" "$bucket_file"
#
#  get_object_lock_configuration "$BUCKET_ONE_NAME" || fail "error getting lock configuration"
#  # shellcheck disable=SC2154
#  log 5 "$lock_config"
#  enabled=$(echo "$lock_config" | jq -r ".ObjectLockConfiguration.ObjectLockEnabled")
#  [[ $enabled == "Enabled" ]] || fail "ObjectLockEnabled should be 'Enabled', is '$enabled'"
#
#  put_object_legal_hold "$BUCKET_ONE_NAME" "$bucket_file" "ON" || fail "error putting legal hold on object"
#  get_object_legal_hold "$BUCKET_ONE_NAME" "$bucket_file" || fail "error getting object legal hold status"
#  # shellcheck disable=SC2154
#  log 5 "$legal_hold"
#  hold_status=$(echo "$legal_hold" | grep -v "InsecureRequestWarning" | jq -r ".LegalHold.Status" 2>&1) || fail "error obtaining hold status: $hold_status"
#  [[ $hold_status == "ON" ]] || fail "Status should be 'ON', is '$hold_status'"
#
#  echo "fdkljafajkfs" > "$test_file_folder/$bucket_file"
#  if put_object_with_user "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" "$username" "$password"; then
#    fail "able to overwrite object with hold"
#  fi
#  # shellcheck disable=SC2154
#  #[[ $put_object_error == *"Object is WORM protected and cannot be overwritten"* ]] || fail "unexpected error message: $put_object_error"
#
#  if delete_object_with_user "s3api" "$BUCKET_ONE_NAME" "$bucket_file" "$username" "$password"; then
#    fail "able to delete object with hold"
#  fi
#  # shellcheck disable=SC2154
#  [[ $delete_object_error == *"Object is WORM protected and cannot be overwritten"* ]] || fail "unexpected error message: $delete_object_error"
#  put_object_legal_hold "$BUCKET_ONE_NAME" "$bucket_file" "OFF" || fail "error removing legal hold on object"
#  delete_object_with_user "s3api" "$BUCKET_ONE_NAME" "$bucket_file" "$username" "$password" || fail "error deleting object after removing legal hold"
#
#  delete_bucket_recursive "s3api" "$BUCKET_ONE_NAME"
#}

#@test "test_get_put_object_retention" {
#  # bucket must be created with lock for legal hold
#  if [[ $RECREATE_BUCKETS == false ]]; then
#    return
#  fi
#
#  bucket_file="bucket_file"
#  username="ABCDEFG"
#  secret_key="HIJKLMN"
#
#  legal_hold_retention_setup "$username" "$secret_key" "$bucket_file"
#
#  get_object_lock_configuration "$BUCKET_ONE_NAME" || fail "error getting lock configuration"
#  log 5 "$lock_config"
#  enabled=$(echo "$lock_config" | jq -r ".ObjectLockConfiguration.ObjectLockEnabled")
#  [[ $enabled == "Enabled" ]] || fail "ObjectLockEnabled should be 'Enabled', is '$enabled'"
#
#  if [[ "$OSTYPE" == "darwin"* ]]; then
#    retention_date=$(date -v+2d +"%Y-%m-%dT%H:%M:%S")
#  else
#    retention_date=$(date -d "+2 days" +"%Y-%m-%dT%H:%M:%S")
#  fi
#  put_object_retention "$BUCKET_ONE_NAME" "$bucket_file" "GOVERNANCE" "$retention_date" || fail "failed to add object retention"
#  get_object_retention "$BUCKET_ONE_NAME" "$bucket_file" || fail "failed to get object retention"
#  log 5 "$retention"
#  retention=$(echo "$retention" | grep -v "InsecureRequestWarning")
#  mode=$(echo "$retention" | jq -r ".Retention.Mode")
#  retain_until_date=$(echo "$retention" | jq -r ".Retention.RetainUntilDate")
#  [[ $mode == "GOVERNANCE" ]] || fail "retention mode should be governance, is $mode"
#  [[ $retain_until_date == "$retention_date"* ]] || fail "retain until date should be $retention_date, is $retain_until_date"
#
#  echo "fdkljafajkfs" > "$test_file_folder/$bucket_file"
#  put_object_with_user "s3api" "$test_file_folder/$bucket_file" "$BUCKET_ONE_NAME" "$bucket_file" "$username" "$secret_key" || local put_result=$?
#  [[ $put_result -ne 0 ]] || fail "able to overwrite object with hold"
#  [[ $error == *"Object is WORM protected and cannot be overwritten"* ]] || fail "unexpected error message: $error"
#
#  delete_object_with_user "s3api" "$BUCKET_ONE_NAME" "$bucket_file" "$username" "$secret_key" || local delete_result=$?
#  [[ $delete_result -ne 0 ]] || fail "able to delete object with hold"
#  [[ $error == *"Object is WORM protected and cannot be overwritten"* ]] || fail "unexpected error message: $error"
#
#  delete_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file" || fail "error deleting object"
#  delete_bucket_recursive "s3api" "$BUCKET_ONE_NAME"
#}

legal_hold_retention_setup() {
  [[ $# -eq 3 ]] || fail "legal hold or retention setup requires username, secret key, bucket file"

  delete_bucket_or_contents_if_exists "s3api" "$BUCKET_ONE_NAME" || fail "error deleting bucket, or checking for existence"
  setup_user "$1" "$2" "user" || fail "error creating user if nonexistent"
  create_test_files "$3" || fail "error creating test files"

  #create_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error creating bucket"
  create_bucket_object_lock_enabled "$BUCKET_ONE_NAME" || fail "error creating bucket"
  change_bucket_owner "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$BUCKET_ONE_NAME" "$1" || fail "error changing bucket ownership"
  get_bucket_policy "s3api" "$BUCKET_ONE_NAME" || fail "error getting bucket policy"
  log 5 "POLICY: $bucket_policy"
  get_bucket_owner "$BUCKET_ONE_NAME"
  log 5 "owner: $bucket_owner"
  #put_bucket_ownership_controls "$BUCKET_ONE_NAME" "BucketOwnerPreferred" || fail "error putting bucket ownership controls"
  put_object_with_user "s3api" "$test_file_folder/$3" "$BUCKET_ONE_NAME" "$3" "$1" "$2" || fail "failed to add object to bucket"
}

@test "test_put_bucket_acl" {
  test_common_put_bucket_acl "s3api"
}

# test v1 s3api list objects command
@test "test-s3api-list-objects-v1" {
  local object_one="test-file-one"
  local object_two="test-file-two"
  local object_two_data="test data\n"

  create_test_files "$object_one" "$object_two" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  printf "%s" "$object_two_data" > "$test_file_folder"/"$object_two"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local result=$?
  [[ $result -eq 0 ]] || fail "Failed to create bucket '$BUCKET_ONE_NAME'"
  put_object "s3api" "$test_file_folder"/"$object_one" "$BUCKET_ONE_NAME" "$object_one" || local copy_result_one=$?
  [[ $copy_result_one -eq 0 ]] || fail "Failed to add object $object_one"
  put_object "s3api" "$test_file_folder"/"$object_two" "$BUCKET_ONE_NAME" "$object_two" || local copy_result_two=$?
  [[ $copy_result_two -eq 0 ]] || fail "Failed to add object $object_two"

  list_objects_s3api_v1 "$BUCKET_ONE_NAME"
  key_one=$(echo "$objects" | jq -r '.Contents[0].Key')
  [[ $key_one == "$object_one" ]] || fail "Object one mismatch ($key_one, $object_one)"
  size_one=$(echo "$objects" | jq -r '.Contents[0].Size')
  [[ $size_one -eq 0 ]] || fail "Object one size mismatch ($size_one, 0)"
  key_two=$(echo "$objects" | jq -r '.Contents[1].Key')
  [[ $key_two == "$object_two" ]] || fail "Object two mismatch ($key_two, $object_two)"
  size_two=$(echo "$objects" | jq '.Contents[1].Size')
  [[ $size_two -eq ${#object_two_data} ]] || fail "Object two size mismatch ($size_two, ${#object_two_data})"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$object_one" "$object_two"
}

# test v2 s3api list objects command
@test "test-s3api-list-objects-v2" {
  local object_one="test-file-one"
  local object_two="test-file-two"
  local object_two_data="test data\n"

  create_test_files "$object_one" "$object_two" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  printf "%s" "$object_two_data" > "$test_file_folder"/"$object_two"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local result=$?
  [[ $result -eq 0 ]] || fail "Failed to create bucket '$BUCKET_ONE_NAME'"
  put_object "s3api" "$test_file_folder"/"$object_one" "$BUCKET_ONE_NAME" "$object_one" || local copy_object_one=$?
  [[ $copy_object_one -eq 0 ]] || fail "Failed to add object $object_one"
  put_object "s3api" "$test_file_folder"/"$object_two" "$BUCKET_ONE_NAME" "$object_two" || local copy_object_two=$?
  [[ $copy_object_two -eq 0 ]] || fail "Failed to add object $object_two"

  list_objects_s3api_v2 "$BUCKET_ONE_NAME"
  key_one=$(echo "$objects" | jq -r '.Contents[0].Key')
  [[ $key_one == "$object_one" ]] || fail "Object one mismatch ($key_one, $object_one)"
  size_one=$(echo "$objects" | jq -r '.Contents[0].Size')
  [[ $size_one -eq 0 ]] || fail "Object one size mismatch ($size_one, 0)"
  key_two=$(echo "$objects" | jq -r '.Contents[1].Key')
  [[ $key_two == "$object_two" ]] || fail "Object two mismatch ($key_two, $object_two)"
  size_two=$(echo "$objects" | jq -r '.Contents[1].Size')
  [[ $size_two -eq ${#object_two_data} ]] || fail "Object two size mismatch ($size_two, ${#object_two_data})"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$object_one" "$object_two"
}

# test abilty to set and retrieve object tags
@test "test-set-get-object-tags" {
  test_common_set_get_object_tags "aws"
}

# test multi-part upload list parts command
@test "test-multipart-upload-list-parts" {
  local bucket_file="bucket-file"

  create_test_files "$bucket_file" || fail "error creating test file"
  dd if=/dev/urandom of="$test_file_folder/$bucket_file" bs=5M count=1 || fail "error creating test file"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "failed to create bucket '$BUCKET_ONE_NAME'"

  list_parts "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 || fail "listing multipart upload parts failed"

  declare -a parts_map
  # shellcheck disable=SC2154
  log 5 "parts: $parts"
  for i in {0..3}; do
    local part_number
    local etag
    # shellcheck disable=SC2154
    part=$(echo "$parts" | grep -v "InsecureRequestWarning" | jq -r ".[$i]" 2>&1) || fail "error getting part: $part"
    part_number=$(echo "$part" | jq ".PartNumber" 2>&1) || fail "error parsing part number: $part_number"
    [[ $part_number != "" ]] || fail "error:  blank part number"

    etag=$(echo "$part" | jq ".ETag" 2>&1) || fail "error parsing etag: $etag"
    [[ $etag != "" ]] || fail "error:  blank etag"
    # shellcheck disable=SC2004
    parts_map[$part_number]=$etag
  done
  [[ ${#parts_map[@]} -ne 0 ]] || fail "error loading multipart upload parts to check"

  for i in {0..3}; do
    local part_number
    local etag
    # shellcheck disable=SC2154
    listed_part=$(echo "$listed_parts" | grep -v "InsecureRequestWarning" | jq -r ".Parts[$i]" 2>&1) || fail "error parsing listed part: $listed_part"
    part_number=$(echo "$listed_part" | jq ".PartNumber" 2>&1) || fail "error parsing listed part number: $part_number"
    etag=$(echo "$listed_part" | jq ".ETag" 2>&1) || fail "error getting listed etag: $etag"
    [[ ${parts_map[$part_number]} == "$etag" ]] || fail "error:  etags don't match (part number: $part_number, etags ${parts_map[$part_number]},$etag)"
  done

  run_then_abort_multipart_upload "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder/$bucket_file" 4
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

# test listing of active uploads
@test "test-multipart-upload-list-uploads" {
  local bucket_file_one="bucket-file-one"
  local bucket_file_two="bucket-file-two"

  if [[ $RECREATE_BUCKETS == false ]]; then
    abort_all_multipart_uploads "$BUCKET_ONE_NAME" || fail "error aborting all uploads"
  fi

  create_test_files "$bucket_file_one" "$bucket_file_two" || fail "error creating test files"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "failed to create bucket '$BUCKET_ONE_NAME'"

  create_and_list_multipart_uploads "$BUCKET_ONE_NAME" "$test_file_folder"/"$bucket_file_one" "$test_file_folder"/"$bucket_file_two" || fail "failed to list multipart uploads"

  local key_one
  local key_two
  # shellcheck disable=SC2154
  log 5 "Uploads:  $uploads"
  raw_uploads=$(echo "$uploads" | grep -v "InsecureRequestWarning")
  key_one=$(echo "$raw_uploads" | jq -r '.Uploads[0].Key' 2>&1) || fail "error getting key one: $key_one"
  key_two=$(echo "$raw_uploads" | jq -r '.Uploads[1].Key' 2>&1) || fail "error getting key two: $key_two"
  key_one=${key_one//\"/}
  key_two=${key_two//\"/}
  [[ "$test_file_folder/$bucket_file_one" == *"$key_one" ]] || fail "Key mismatch ($test_file_folder/$bucket_file_one, $key_one)"
  [[ "$test_file_folder/$bucket_file_two" == *"$key_two" ]] || fail "Key mismatch ($test_file_folder/$bucket_file_two, $key_two)"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$bucket_file_one" "$bucket_file_two"
}

@test "test-multipart-upload-from-bucket" {
  local bucket_file="bucket-file"

  create_test_files "$bucket_file" || local created=$?
  [[ $created -eq 0 ]] || fail "Error creating test files"
  dd if=/dev/urandom of="$test_file_folder/$bucket_file" bs=5M count=1 || fail "error creating test file"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local result=$?
  [[ $result -eq 0 ]] || fail "Failed to create bucket '$BUCKET_ONE_NAME'"

  multipart_upload_from_bucket "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 || upload_result=$?
  [[ $upload_result -eq 0 ]] || fail "Error performing multipart upload"

  get_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file-copy" "$test_file_folder/$bucket_file-copy"
  compare_files "$test_file_folder"/$bucket_file-copy "$test_file_folder"/$bucket_file || compare_result=$?
  [[ $compare_result -eq 0 ]] || fail "Data doesn't match"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

@test "test_multipart_upload_from_bucket_range_too_large" {
  local bucket_file="bucket-file"

  create_large_file "$bucket_file" || error creating file "$bucket_file"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "Failed to create bucket '$BUCKET_ONE_NAME'"

  multipart_upload_from_bucket_range "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 "bytes=0-1000000000" || local upload_result=$?
  [[ $upload_result -eq 1 ]] || fail "multipart upload with overly large range should have failed"
  log 5 "error: $upload_part_copy_error"
  [[ $upload_part_copy_error == *"Range specified is not valid"* ]] || [[ $upload_part_copy_error == *"InvalidRange"* ]] || fail "unexpected error: $upload_part_copy_error"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

@test "test_multipart_upload_from_bucket_range_valid" {
  local bucket_file="bucket-file"

  create_large_file "$bucket_file" || error creating file "$bucket_file"
  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "Failed to create bucket '$BUCKET_ONE_NAME'"

  range_max=$((5*1024*1024-1))
  multipart_upload_from_bucket_range "$BUCKET_ONE_NAME" "$bucket_file" "$test_file_folder"/"$bucket_file" 4 "bytes=0-$range_max" || fail "upload failure"

  get_object "s3api" "$BUCKET_ONE_NAME" "$bucket_file-copy" "$test_file_folder/$bucket_file-copy" || fail "error retrieving object after upload"
  if [[ $(uname) == 'Darwin' ]]; then
    object_size=$(stat -f%z "$test_file_folder/$bucket_file-copy")
  else
    object_size=$(stat --format=%s "$test_file_folder/$bucket_file-copy")
  fi
  [[ object_size -eq $((range_max*4+4)) ]] || fail "object size mismatch ($object_size, $((range_max*4+4)))"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $bucket_file
}

@test "test-presigned-url-utf8-chars" {
  test_common_presigned_url_utf8_chars "aws"
}

@test "test-list-objects-delimiter" {
  folder_name="two"
  object_name="three"
  create_test_folder "$folder_name" || fail "error creating folder"
  create_test_files "$folder_name"/"$object_name" || fail "error creating file"

  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "error setting up bucket"

  put_object "aws" "$test_file_folder/$folder_name/$object_name" "$BUCKET_ONE_NAME" "$folder_name/$object_name" || fail "failed to add object to bucket"

  list_objects_s3api_v1 "$BUCKET_ONE_NAME" "/"
  prefix=$(echo "${objects[@]}" | jq -r ".CommonPrefixes[0].Prefix" 2>&1) || fail "error getting object prefix from object list: $prefix"
  [[ $prefix == "$folder_name/" ]] || fail "prefix doesn't match (expected $prefix, actual $folder_name/)"

  list_objects_s3api_v1 "$BUCKET_ONE_NAME" "#"
  key=$(echo "${objects[@]}" | jq -r ".Contents[0].Key" 2>&1) || fail "error getting key from object list: $key"
  [[ $key == "$folder_name/$object_name" ]] || fail "key doesn't match (expected $key, actual $folder_name/$object_name)"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files $folder_name
}

#@test "test_put_policy_no_version" {
#  policy_file="policy_file"
#
#  create_test_files "$policy_file" || fail "error creating policy file"
#
#  effect="Allow"
#  principal="*"
#  action="s3:GetObject"
#  resource="arn:aws:s3:::$BUCKET_ONE_NAME/*"
#
#  cat <<EOF > "$test_file_folder"/$policy_file
#    {
#      "Statement": [
#        {
#           "Effect": "$effect",
#           "Principal": "$principal",
#           "Action": "$action",
#           "Resource": "$resource"
#        }
#      ]
#    }
#EOF
#
#    setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
#
#    check_for_empty_policy "s3api" "$BUCKET_ONE_NAME" || fail "policy not empty"
#
#    put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
#
#    get_bucket_policy "s3api" "$BUCKET_ONE_NAME" || fail "unable to retrieve policy"
#}

@test "test_put_policy_invalid_action" {
  policy_file="policy_file"

  create_test_files "$policy_file" || fail "error creating policy file"

  effect="Allow"
  principal="*"
  action="s3:GetObjectt"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/*"

  cat <<EOF > "$test_file_folder"/$policy_file
    {
      "Statement": [
        {
           "Effect": "$effect",
           "Principal": "$principal",
           "Action": "$action",
           "Resource": "$resource"
        }
      ]
    }
EOF

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"

  check_for_empty_policy "s3api" "$BUCKET_ONE_NAME" || fail "policy not empty"

  if put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file"; then
    fail "put succeeded despite malformed policy"
  fi
  # shellcheck disable=SC2154
  [[ "$put_bucket_policy_error" == *"MalformedPolicy"*"invalid action"* ]] || fail "invalid policy error: $put_bucket_policy_error"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file"
}

@test "test_policy_get_object_with_user" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file"
  username="ABCDEFG"
  password="HIJKLMN"
  test_file="test_file"

  create_test_files "$test_file" "$policy_file" || fail "error creating policy file"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_file"

  effect="Allow"
  principal="$username"
  action="s3:GetObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/$test_file"

  setup_policy_with_single_statement "$test_file_folder/$policy_file" "2012-10-17" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  put_object "s3api" "$test_file_folder/$test_file" "$BUCKET_ONE_NAME" "$test_file" || fail "error copying object"

  if ! check_for_empty_policy "s3api" "$BUCKET_ONE_NAME"; then
    delete_bucket_policy "s3api" "$BUCKET_ONE_NAME" || fail "error deleting policy"
    check_for_empty_policy "s3api" "$BUCKET_ONE_NAME" || fail "policy not empty after deletion"
  fi

  setup_user "$username" "$password" "user" || fail "error creating user"
  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file" "$test_file_folder/$test_file-copy" "$username" "$password"; then
    fail "get object with user succeeded despite lack of permissions"
  fi
  # shellcheck disable=SC2154
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"

  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file" "$test_file_folder/$test_file-copy" "$username" "$password" || fail "error getting object after permissions"
  compare_files "$test_file_folder/$test_file" "$test_file_folder/$test_file-copy" || fail "files not equal"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

@test "test_policy_get_object_specific_file" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file"
  test_file="test_file"
  test_file_two="test_file_two"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" "$test_file" "$test_file_two" || fail "error creating policy file"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_file"
  echo "$BATS_TEST_NAME-2" >> "$test_file_folder/$test_file_two"

  effect="Allow"
  principal="$username"
  action="s3:GetObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/test_file"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"

  put_object "s3api" "$test_file_folder/$test_file" "$BUCKET_ONE_NAME" "$test_file" || fail "error copying object"
  put_object "s3api" "$test_file_folder/$test_file_two" "$BUCKET_ONE_NAME" "$test_file_two" || fail "error copying object"

  get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file" "$test_file_folder/$test_file-copy" "$username" "$password" || fail "error getting object after permissions"
  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file_two" "$test_file_folder/$test_file_two-copy" "$username" "$password"; then
    fail "get object with user succeeded despite lack of permissions"
  fi
  # shellcheck disable=SC2154
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

@test "test_policy_get_object_file_wildcard" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file_one"
  policy_file_two="policy_file_two"
  policy_file_three="policy_fil"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" "$policy_file_two" "$policy_file_three" || fail "error creating policy file"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$policy_file"

  effect="Allow"
  principal="$username"
  action="s3:GetObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/policy_file*"

  setup_user "$username" "$password" "user" || fail "error creating user account"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"

  put_object "s3api" "$test_file_folder/$policy_file" "$BUCKET_ONE_NAME" "$policy_file" || fail "error copying object one"
  put_object "s3api" "$test_file_folder/$policy_file_two" "$BUCKET_ONE_NAME" "$policy_file_two" || fail "error copying object two"
  put_object "s3api" "$test_file_folder/$policy_file_three" "$BUCKET_ONE_NAME" "$policy_file_three" || fail "error copying object three"

  get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$policy_file" "$test_file_folder/$policy_file" "$username" "$password" || fail "error getting object one after permissions"
  get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$policy_file_two" "$test_file_folder/$policy_file_two" "$username" "$password" || fail "error getting object two after permissions"
  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$policy_file_three" "$test_file_folder/$policy_file_three" "$username" "$password"; then
    fail "get object three with user succeeded despite lack of permissions"
  fi
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

@test "test_policy_get_object_folder_wildcard" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file"
  test_folder="test_folder"
  test_file="test_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_folder "$test_folder" || fail "error creating test folder"
  create_test_files "$test_folder/$test_file" "$policy_file" || fail "error creating policy file, test file"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_folder/$test_file"

  effect="Allow"
  principal="$username"
  action="s3:GetObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/$test_folder/*"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"

  put_object "s3api" "$test_file_folder/$test_folder/$test_file" "$BUCKET_ONE_NAME" "$test_folder/$test_file" || fail "error copying object to bucket"

  download_and_compare_file_with_user "s3api" "$test_file_folder/$test_folder/$test_file" "$BUCKET_ONE_NAME" "$test_folder/$test_file" "$test_file_folder/$test_file-copy" "$username" "$password" || fail "error downloading and comparing file"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$test_folder/$test_file" "$policy_file"
}

@test "test_policy_allow_deny" {
  policy_file="policy_file"
  test_file="test_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" "$test_file" || fail "error creating policy file"

  principal="$username"
  action="s3:GetObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/$test_file"

  cat <<EOF > "$test_file_folder"/$policy_file
    {
      "Statement": [
        {
           "Effect": "Deny",
           "Principal": "$principal",
           "Action": "$action",
           "Resource": "$resource"
        },
        {
           "Effect": "Allow",
           "Principal": "$principal",
           "Action": "$action",
           "Resource": "$resource"
        }
      ]
    }
EOF

  setup_user "$username" "$password" "user" || fail "error creating user"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  put_object "s3api" "$test_file_folder/$test_file" "$BUCKET_ONE_NAME" "$test_file" || fail "error copying object to bucket"

  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file" "$test_file_folder/$test_file-copy" "$username" "$password"; then
    fail "able to get object despite deny statement"
  fi
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$test_file" "$test_file-copy" "$policy_file"
}

@test "test_policy_deny" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file"
  test_file_one="test_file_one"
  test_file_two="test_file_two"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$test_file_one" "$test_file_two" "$policy_file" || fail "error creating policy file, test file"

  cat <<EOF > "$test_file_folder"/$policy_file
{
  "Statement": [
    {
       "Effect": "Deny",
       "Principal": "$username",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::$BUCKET_ONE_NAME/$test_file_two"
    },
    {
       "Effect": "Allow",
       "Principal": "$username",
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::$BUCKET_ONE_NAME/*"
    }
  ]
}
EOF

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  log 5 "Policy: $(cat "$test_file_folder/$policy_file")"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  put_object "s3api" "$test_file_folder/$test_file_one" "$BUCKET_ONE_NAME" "$test_file_one" || fail "error copying object one"
  put_object "s3api" "$test_file_folder/$test_file_one" "$BUCKET_ONE_NAME" "$test_file_two" || fail "error copying object two"
  get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file_one" "$test_file_folder/$test_file_one-copy" "$username" "$password" || fail "error getting object"
  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file_two" "$test_file_folder/$test_file_two-copy" "$username" "$password"; then
    fail "able to get object despite deny statement"
  fi
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$test_file_one" "$test_file_two" "$test_file_one-copy" "$test_file_two-copy" "$policy_file"
}

@test "test_policy_put_wildcard" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi

  policy_file="policy_file"
  test_folder="test_folder"
  test_file="test_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_folder "$test_folder" || fail "error creating test folder"
  create_test_files "$test_folder/$test_file" "$policy_file" || fail "error creating policy file, test file"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_folder/$test_file"

  effect="Allow"
  principal="$username"
  action="s3:PutObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/$test_folder/*"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  log 5 "Policy: $(cat "$test_file_folder/$policy_file")"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  if put_object_with_user "s3api" "$test_file_folder/$test_folder/$test_file" "$BUCKET_ONE_NAME" "$test_file" "$username" "$password"; then
    fail "able to put object despite not being allowed"
  fi
  [[ "$put_object_error" == *"Access Denied"* ]] || fail "invalid put object error: $put_object_error"
  put_object_with_user "s3api" "$test_file_folder/$test_folder/$test_file" "$BUCKET_ONE_NAME" "$test_folder/$test_file" "$username" "$password" || fail "error putting file despite policy permissions"
  if get_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_folder/$test_file" "$test_folder/$test_file-copy" "$username" "$password"; then
    fail "able to get object without permissions"
  fi
  [[ "$get_object_error" == *"Access Denied"* ]] || fail "invalid get object error: $get_object_error"
  download_and_compare_file "s3api" "$test_file_folder/$test_folder/$test_file" "$BUCKET_ONE_NAME" "$test_folder/$test_file" "$test_file_folder/$test_file-copy" || fail "files don't match"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$test_folder/$test_file" "$test_file-copy" "$policy_file"
}

@test "test_policy_delete" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  test_file_one="test_file_one"
  test_file_two="test_file_two"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$test_file_one" "$test_file_two" "$policy_file" || fail "error creating policy file, test files"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_file_one"
  echo "$BATS_TEST_NAME" >> "$test_file_folder/$test_file_two"

  effect="Allow"
  principal="$username"
  action="s3:DeleteObject"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME/$test_file_two"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  log 5 "Policy: $(cat "$test_file_folder/$policy_file")"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"

  put_object "s3api" "$test_file_folder/$test_file_one" "$BUCKET_ONE_NAME" "$test_file_one" || fail "error copying object one"
  put_object "s3api" "$test_file_folder/$test_file_two" "$BUCKET_ONE_NAME" "$test_file_two" || fail "error copying object two"
  if delete_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file_one" "$username" "$password"; then
    fail "able to delete object despite lack of permissions"
  fi
  [[ "$delete_object_error" == *"Access Denied"* ]] || fail "invalid delete object error: $delete_object_error"
  delete_object_with_user "s3api" "$BUCKET_ONE_NAME" "$test_file_two" "$username" "$password" || fail "error deleting object despite permissions"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$test_file_one" "$test_file_two" "$policy_file"
}

@test "test_policy_get_bucket_policy" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" || fail "error creating policy file, test files"

  effect="Allow"
  principal="$username"
  action="s3:GetBucketPolicy"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  if get_bucket_policy_with_user "$BUCKET_ONE_NAME" "$username" "$password"; then
    fail "able to retrieve bucket policy despite lack of permissions"
  fi

  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  get_bucket_policy_with_user "$BUCKET_ONE_NAME" "$username" "$password" || fail "error getting bucket policy despite permissions"
  # shellcheck disable=SC2154
  echo "$bucket_policy" > "$test_file_folder/$policy_file-copy"
  log 5 "ORIG: $(cat "$test_file_folder/$policy_file")"
  log 5 "COPY: $(cat "$test_file_folder/$policy_file-copy")"
  compare_files "$test_file_folder/$policy_file" "$test_file_folder/$policy_file-copy" || fail "policies not equal"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file" "$policy_file-copy"
}

@test "test_policy_list_multipart_uploads" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  test_file="test_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" || fail "error creating policy file, test files"
  create_large_file "$test_file" || error creating file "$test_file"

  effect="Allow"
  principal="$username"
  action="s3:ListBucketMultipartUploads"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  create_multipart_upload "$BUCKET_ONE_NAME" "$test_file" || fail "error creating multipart upload"
  if list_multipart_uploads_with_user "$BUCKET_ONE_NAME" "$username" "$password"; then
    log 2 "able to list multipart uploads despite lack of permissions"
  fi
  # shellcheck disable=SC2154
  [[ "$list_multipart_uploads_error" == *"Access Denied"* ]] || fail "invalid list multipart uploads error: $list_multipart_uploads_error"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  list_multipart_uploads_with_user "$BUCKET_ONE_NAME" "$username" "$password" || fail "error listing multipart uploads"
  log 5 "$uploads"
  upload_key=$(echo "$uploads" | grep -v "InsecureRequestWarning" | jq -r ".Uploads[0].Key" 2>&1) || fail "error parsing upload key from uploads message: $upload_key"
  [[ $upload_key == "$test_file" ]] || fail "upload key doesn't match file marked as being uploaded"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file" "$test_file"
}

@test "test_policy_put_bucket_policy" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  policy_file_two="policy_file_two"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" || fail "error creating policy file, test files"

  effect="Allow"
  principal="$username"
  action="s3:PutBucketPolicy"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  if put_bucket_policy_with_user "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" "$username" "$password"; then
    fail "able to retrieve bucket policy despite lack of permissions"
  fi

  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  setup_policy_with_single_statement "$test_file_folder/$policy_file_two" "dummy" "$effect" "$principal" "s3:GetBucketPolicy" "$resource" || fail "failed to set up policy"
  put_bucket_policy_with_user "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file_two" "$username" "$password" || fail "error putting bucket policy despite permissions"
  get_bucket_policy_with_user "$BUCKET_ONE_NAME" "$username" "$password" || fail "error getting bucket policy despite permissions"
  # shellcheck disable=SC2154
  echo "$bucket_policy" > "$test_file_folder/$policy_file-copy"
  log 5 "ORIG: $(cat "$test_file_folder/$policy_file_two")"
  log 5 "COPY: $(cat "$test_file_folder/$policy_file-copy")"
  compare_files "$test_file_folder/$policy_file_two" "$test_file_folder/$policy_file-copy" || fail "policies not equal"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file" "$policy_file_two" "$policy_file-copy"
}

@test "test_policy_delete_bucket_policy" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" || fail "error creating policy file, test files"

  effect="Allow"
  principal="$username"
  action="s3:DeleteBucketPolicy"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  if delete_bucket_policy_with_user "$BUCKET_ONE_NAME" "$username" "$password"; then
    fail "able to delete bucket policy with user $username without right permissions"
  fi
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  delete_bucket_policy_with_user "$BUCKET_ONE_NAME" "$username" "$password" || fail "unable to delete bucket policy"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file"
}

@test "test_policy_get_bucket_acl" {
  # TODO (https://github.com/versity/versitygw/issues/637)
  if [[ $RECREATE_BUCKETS == "false" ]]; then
    return 0
  fi
  policy_file="policy_file"
  username="ABCDEFG"
  password="HIJKLMN"

  create_test_files "$policy_file" || fail "error creating policy file, test files"

  effect="Allow"
  principal="$username"
  action="s3:GetBucketAcl"
  resource="arn:aws:s3:::$BUCKET_ONE_NAME"

  setup_user "$username" "$password" "user" || fail "error creating user"

  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  #put_bucket_canned_acl "$BUCKET_ONE_NAME" "private" || fail "error putting bucket canned ACL"
  if get_bucket_acl_with_user "$BUCKET_ONE_NAME" "$username" "$password"; then
    fail "user able to get bucket ACLs despite permissions"
  fi
  setup_policy_with_single_statement "$test_file_folder/$policy_file" "dummy" "$effect" "$principal" "$action" "$resource" || fail "failed to set up policy"
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  get_bucket_acl_with_user "$BUCKET_ONE_NAME" "$username" "$password" || fail "error getting bucket ACL despite permissions"
}

# ensure that lists of files greater than a size of 1000 (pagination) are returned properly
#@test "test_list_objects_file_count" {
#  test_common_list_objects_file_count "aws"
#}

#@test "test_filename_length" {
#  file_name=$(printf "%0.sa" $(seq 1 1025))
#  echo "$file_name"


# ensure that lists of files greater than a size of 1000 (pagination) are returned properly
#@test "test_list_objects_file_count" {
#  test_common_list_objects_file_count "aws"
#}

#@test "test_filename_length" {
#  file_name=$(printf "%0.sa" $(seq 1 1025))
#  echo "$file_name"

#  create_test_files "$file_name" || created=$?
#  [[ $created -eq 0 ]] || fail "error creating file"

#  setup_bucket "aws" "$BUCKET_ONE_NAME" || local setup_result=$?
#  [[ $setup_result -eq 0 ]] || fail "error setting up bucket"

#  put_object "aws" "$test_file_folder"/"$file_name" "$BUCKET_ONE_NAME"/"$file_name" || local put_object=$?
#  [[ $put_object -eq 0 ]] || fail "Failed to add object to bucket"
#}

@test "test_head_bucket" {
  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  head_bucket "aws" "$BUCKET_ONE_NAME" || fail "error getting bucket info"
  log 5 "INFO:  $bucket_info"
  region=$(echo "$bucket_info" | grep -v "InsecureRequestWarning" | jq -r ".BucketRegion" 2>&1) || fail "error getting bucket region: $region"
  [[ $region != "" ]] || fail "empty bucket region"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

@test "test_head_bucket_invalid_name" {
  if head_bucket "aws" ""; then
    fail "able to get bucket info for invalid name"
  fi
}

@test "test_head_bucket_doesnt_exist" {
  setup_bucket "aws" "$BUCKET_ONE_NAME" || local setup_result=$?
  [[ $setup_result -eq 0 ]] || fail "error setting up bucket"
  head_bucket "aws" "$BUCKET_ONE_NAME"a || local info_result=$?
  [[ $info_result -eq 1 ]] || fail "bucket info for non-existent bucket returned"
  [[ $bucket_info == *"404"* ]] || fail "404 not returned for non-existent bucket info"
  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
}

@test "test_add_object_metadata" {
  object_one="object-one"
  test_key="x-test-data"
  test_value="test-value"

  create_test_files "$object_one" || fail "error creating test files"

  setup_bucket "aws" "$BUCKET_ONE_NAME" || fail "error setting up bucket"

  object="$test_file_folder"/"$object_one"
  put_object_with_metadata "aws" "$object" "$BUCKET_ONE_NAME" "$object_one" "$test_key" "$test_value" || fail "failed to add object to bucket"
  object_exists "aws" "$BUCKET_ONE_NAME" "$object_one" || fail "object not found after being added to bucket"

  get_object_metadata "aws" "$BUCKET_ONE_NAME" "$object_one" || fail "error getting object metadata"
  key=$(echo "$metadata" | jq -r 'keys[]' 2>&1) || fail "error getting key from metadata: $key"
  value=$(echo "$metadata" | jq -r '.[]' 2>&1) || fail "error getting value from metadata: $value"
  [[ $key == "$test_key" ]] || fail "keys doesn't match (expected $key, actual \"$test_key\")"
  [[ $value == "$test_value" ]] || fail "values doesn't match (expected $value, actual \"$test_value\")"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$object_one"
}

@test "test_policy_abort_multipart_upload" {
  policy_file="policy_file"
  test_file="test_file"
  username="ABCDEFG"

  create_test_files "$policy_file" || fail "error creating policy file"
  create_large_file "$test_file" || fail "error creating large file"
  setup_bucket "s3api" "$BUCKET_ONE_NAME" || fail "error setting up bucket"
  if [[ $DIRECT == "true" ]]; then
    setup_user_direct "$username" "user" "$BUCKET_ONE_NAME" || fail "error setting up direct user $username"
    principal="{\"AWS\": \"arn:aws:iam::$DIRECT_AWS_USER_ID:user/$username\"}"
    # shellcheck disable=SC2154
    username=$key_id
    # shellcheck disable=SC2154
    password=$secret_key
  else
    password="HIJLKMN"
    setup_user "$username" "$password" "user" || fail "error setting up user $username"
    principal="\"$username\""
  fi

  cat <<EOF > "$test_file_folder"/$policy_file
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": $principal,
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET_ONE_NAME/*"
    },
    {
      "Effect": "Deny",
      "Principal": $principal,
      "Action": "s3:AbortMultipartUpload",
      "Resource": "arn:aws:s3:::$BUCKET_ONE_NAME/*"
    }
  ]
}
EOF
  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting first policy"

  create_multipart_upload_with_user "$BUCKET_ONE_NAME" "$test_file" "$username" "$password" || fail "error creating multipart upload"
  if abort_multipart_upload_with_user "$BUCKET_ONE_NAME" "$test_file" "$upload_id" "$username" "$password"; then
    fail "abort multipart upload succeeded despite lack of permissions"
  fi
  # shellcheck disable=SC2154
  [[ "$abort_multipart_upload_error" == *"AccessDenied"* ]] || fail "unexpected abort error:  $abort_multipart_upload_error"

  cat <<EOF > "$test_file_folder"/$policy_file
{
  "Version": "2012-10-17",
  "Statement": [
    {
       "Effect": "Allow",
       "Principal": $principal,
       "Action": "s3:AbortMultipartUpload",
       "Resource": "arn:aws:s3:::$BUCKET_ONE_NAME/*"
    }
  ]
}
EOF

  put_bucket_policy "s3api" "$BUCKET_ONE_NAME" "$test_file_folder/$policy_file" || fail "error putting policy"
  abort_multipart_upload_with_user "$BUCKET_ONE_NAME" "$test_file" "$upload_id" "$username" "$password" || fail "error aborting multipart upload despite permissions"

  delete_bucket_or_contents "aws" "$BUCKET_ONE_NAME"
  delete_test_files "$policy_file" "$test_file"
}
