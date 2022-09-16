#!/bin/bash
#set -x
base_dir=/Users/edn/cs/prj/datamesh-on-gcp/oneclick
usage_and_exit() {
    echo "If USERNAME(ldap) PROJECT_DATASTO or PROJECT_DATAGOV environment variables are not set they must be passed in commnad line as follw"
    echo "Usage: ./deploy_helper.sh <ldap> <datastore-projectid> <datagov-projectid> <randid>"
    echo "Example: ./deploy_helper.sh jayoleary my-datastore my-datagov 123"
    exit 1
}

err_exit() {
  echo ERROR $1 
  popd 
  exit 1
}

GCP_ARGOLIS_LDAP=${1:-$USERNAME}
GCP_DATASTORE_PROJECT_ID=${2:-$PROJECT_DATASTO}
GCP_DATAGOV_PROJECT_ID=${3:-$PROJECT_DATAGOV}

[[ -z $GCP_DATASTORE_PROJECT_ID || -z GCP_DATAGOV_PROJECT_ID || -z $GCP_ARGOLIS_LDAP ]] && usage_and_exit


echo "${GCP_DATASTORE_PROJECT_ID}"
pushd ${base_dir}/org_policy
gcloud config set project ${GCP_DATASTORE_PROJECT_ID}
terraform init
terraform apply -auto-approve -var project_id_storage=${GCP_DATASTORE_PROJECT_ID} -var project_id_governance=${GCP_DATAGOV_PROJECT_ID}
status=$?
[ $status -eq 0 ] && echo "command successful" || err_exit "Unable to apply org policy"
 

rm terraform*
popd

pushd ${base_dir}/demo-store/terraform
gcloud config set project ${GCP_DATASTORE_PROJECT_ID}
terraform init
terraform apply -auto-approve -var project_id=${GCP_DATASTORE_PROJECT_ID}
status=$?
[ $status -eq 0 ] && echo "command successful" || err_exit "Unable to apply demo-store"

pushd ${base_dir}/demo-gov/terraform
gcloud config set project ${GCP_DATAGOV_PROJECT_ID}
terraform init

terraform apply -auto-approve -var project_id_governance=${GCP_DATAGOV_PROJECT_ID} -var project_id_storage=${GCP_DATASTORE_PROJECT_ID} -var ldap=${GCP_ARGOLIS_LDAP} -var user_ip_range=10.6.0.0/24

status=$?
[ $status -eq 0 ] && echo "command successful" || err_exit "Unable to apply demo gov"
popd
