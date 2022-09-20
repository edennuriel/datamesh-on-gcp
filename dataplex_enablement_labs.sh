# todo
# rest api wrapper for missing gcloud commands
# automate all the steps in the lab, so I can bring the demo to the end and run it faster in cases when needed
# lanb 2-7
# use local airflow instead of composer for demo purposes
# try perfect instead too 

export LOCATION=us-central1
export LAKES="projects/${PROJECT_DATAGOV}/locations/${LOCATION}/lakes"
debug="echo"
err="log/err"
#dataplex resource

dpr() { 
  fn=cache/$1
  if [[ ! -f $fn ]]; then 
    echo > $fn  
    if [[ $1 == lakes ]];then 
      gcloud dataplex $1 list --location us-central1 --project ${2:-$PROJECT_DATAGOV} --format json | jq -r '.[].name' | tee -a $fn
    else 
      [[ $1 == "zones" ]] && parents=lakes
      [[ $1 == "assets" ]] && parents=zones
      for parent in $($parents); do
          gcloud dataplex $1 list "--${parents/s/}" $parent --location us-central1 --project ${2:-$PROJECT_DATAGOV} --format json | jq -r '.[].name' | tee -a $fn
      done
    fi  
  else 
    cat $fn
  fi
}

lakes() { dpr lakes ;}
zones() { dpr zones ;}
assets() { dpr assets ;}

#dataplex resource policies
dprp() {  
  fn=cache/$1.pol
  if [[ ! -f $fn ]]; then 
    echo > $fn
    for a in $($1); do
      #$debug gcloud dataplex $1 get-iam-policy $a 
      gcloud dataplex $1 get-iam-policy $a --format json \
      | jq -r --arg res $a '.bindings[]|"\($res):\(.members[]|select(.|test("^service"))|.):\(.role)"' 2>$err | tee -a $fn
    done
  else 
    cat $fn
  fi
}

lakes_pol() { dprp lakes ;}
zones_pol() { dprp zones ;}
assets_pol() { dprp assets ;} 

all_pol() { 
  all=cache/demo.pol
  if [[ ! -f $all ]]; then 
    echo > $all
    lakes_pol >> $all
    zones_pol >> $all
    assets_pol >> $all
   fi  
    cat $all
}

remove_bq() { bq ls --format json | jq -r '.[]|.id' | xargs -n1 bq  rm -r -f ;}
remove_buckets() { gsutil ls -p $PROJECT_DATASTO; gsutil ls -p $PROJECT_DATAGOV ;}
remove_lakes() {
  gcloud config set project ${1:-$PROJECT_DATAGOV}
  assets | xargs -n1 gcloud -q dataplex assets delete
  zones | xargs -n1 gcloud -q dataplex zones delete
  lakes | xargs -n1 gcloud -q dataplex lakes delete
}

setup() {
gcloud config set project $PROJECT_DATAGOV
gcloud config set dataplex/location us-central1
}

log_echo() {
  echo >> secure_cmds
  echo "$2" | tee -a $1_cmds
  echo "echo ${2/\#/}" >> $1_cmds
}

secure() {
  customer_sa="serviceAccount:customer-sa@${PROJECT_DATAGOV}.iam.gserviceaccount.com" 
  transactions_sa="serviceAccount:cc-trans-sa@${PROJECT_DATAGOV}.iam.gserviceaccount.com"
  transactions_consumer_sa="serviceAccount:cc-trans-consumer-sa@${PROJECT_DATAGOV}.iam.gserviceaccount.com"
  merchant_sa="serviceAccount:merchant-sa@${PROJECT_DATAGOV}.iam.gserviceaccount.com" 

  echo > secure_cmds
  log_echo secure '# Task 1 Step 1 - provide data owner to service account on source domain'   
  echo gcloud dataplex lakes add-iam-policy-binding prod-customer-source-domain --location $LOCATION  --role roles/dataplex.dataOwner --member="$customer_sa" >> secure_cmds
  
  log_echo secure '# Task 1 Step 2 provide cc sa data reader on product zone in customer domain '
  echo gcloud dataplex zones add-iam-policy-binding $LAKES/prod-customer-source-domain/zones/customer-data-product-zone --member="$transactions_consumer_sa" --role roles/dataplex.dataReader >> secure_cmds
  log_echo secure '# Task 2 Step 1,2,3 give the service accounts owner on da-reports asset and reader on common utility zone in central operation domain '
  sas="$(  gcloud iam service-accounts list --format json | jq '.[]|select(.email|test("customer|merchant|cc-"))|"serviceAccount:\(.email)"')"
  for sa in $sas; do
    echo gcloud dataplex assets add-iam-policy-binding ${LAKES}/central-operations-domain/zones/operations-data-product-zone/assets/dq-reports --member="$sa" --role=roles/dataplex.dataOwner >> secure_cmds
    echo gcloud dataplex zones add-iam-policy-binding ${LAKES}/central-operations-domain/zones/common-utilities --member="$sa" --role=roles/dataplex.dataReader >> secure_cmds
    echo gcloud dataplex zones add-iam-policy-binding "${LAKES}/central-operations-domain/zones/common-utilities" --member="$sa" --role=roles/dataplex.dataReader >> secure_cmds
  done

  log_echo secure  '# Task 2 Step 4 - configure cloud logging and capture the service account ' 
  #check if sink is alrady there, in which case delete it
  log_sink="$(gcloud logging sinks list --format="value(name)" --filter="name=audits-to-bq")"
  [[ $log_sink == "audits-to-bq" ]] && gcloud -q logging sinks delete audits-to-bq
  log_sa="$(gcloud --format json logging --project=${PROJECT_DATAGOV} sinks create audits-to-bq bigquery.googleapis.com/projects/${PROJECT_DATAGOV}/datasets/central_audit_data --log-filter='resource.type="audited_resource" AND resource.labels.service="dataplex.googleapis.com" AND protoPayload.serviceName="dataplex.googleapis.com"' | jq -r '.writerIdentity' 2>&1)" 
  status=$?
  [[ $status -eq 0 ]] && echo "# created sink long sa=$log_sa" | tee -a secure_cmds  || exit 1
  log_echo secure '# Task 2 Step 5 grant logging sa data owner on audit-data asset in product zone '
  echo gcloud dataplex assets add-iam-policy-binding ${LAKES}/central-operations-domain/zones/operations-data-product-zone/assets/audit-data --member="$log_sa" --role=roles/dataplex.dataOwner >> secure_cmds

  log_echo secure '# Task 2 Step 6 enable dlp and give dlp service account access to dlp reports '
  echo enable cloud dlp
  gcloud --project ${PROJECT_DATASTO} services enable dlp.googleapis.com
  echo call DLP service to create the service account
  curl --request POST   "https://dlp.googleapis.com/v2/projects/${PROJECT_DATASTO}/locations/us-central1/content:inspect"   --header "X-Goog-User-Project: ${PROJECT_DATASTO}"   --header "Authorization: Bearer $(gcloud auth print-access-token)"   --header 'Accept: application/json'   --header 'Content-Type: application/json'   --data '{"item":{"value":"google@google.com"}}'   --compressed
  dlp_sa="$(gcloud projects list --format json | jq '.[]|select(.name|test("'${PROJECT_DATASTO}'"))|"serviceAccount:service-\(.projectNumber)@dlp-api.iam.gserviceaccount.com"')"
  echo granting $dlp_sa dataowner on dlp_reports 
  echo gcloud dataplex assets add-iam-policy-binding ${LAKES}/central-operations-domain/zones/operations-data-product-zone/assets/dlp-reports --member="$dlp_sa" --role=roles/dataplex.dataOwner >> secure_cmds
 log_echo secure '# Task 2 Step 7 - monitor security via api '
 echo gcloud dataplex assets describe ${LAKES}/central-operations-domain/zones/operations-data-product-zone/assets/audit-data --format json >> secure_cmds

  log_echo secure '# task 3 step 1 - merchant domain permissions dataowner'
  echo gcloud dataplex lakes add-iam-policy-binding prod-merchant-source-domain --location $LOCATION  --role roles/dataplex.dataOwner --member="$merchant_sa" >> secure_cmds
  log_echo secure '# task 3 step 2 - merchant domain permissions cc-transaction data reader permissions'
  echo gcloud dataplex zones add-iam-policy-binding $LAKES/prod-merchant-source-domain/zones/merchant-data-product-zone --member=$transactions_consumer_sa --role roles/dataplex.dataReader >> secure_cmds

  log_echo secure '# task 4 step 1 - transaction domain owner  permissions'
  echo gcloud dataplex lakes add-iam-policy-binding $LAKES/prod-transactions-source-domain --role roles/dataplex.dataOwner --member="$transactions_sa" >> secure_cmds
  log_echo secure '# task 4 step 2 -  transaction domain owner  permissions'
  echo gcloud dataplex zones add-iam-policy-binding $LAKES/prod-transactions-source-domain/zones/transactions-data-product-zone --member="$transactions_sa" --role roles/dataplex.dataReader >> secure_cmds

  log_echo secure '# task 5 step 1 - transaction consumer domain owner  permissions'
  echo gcloud dataplex lakes add-iam-policy-binding $LAKES/prod-transactions-consumer-domain --role roles/dataplex.dataOwner --member="$transactions_consumer_sa" >> secure_cmds

  log_echo secure '# task 6 step 1 - monitor'
  echo gcloud dataplex assets describe $LAKES/central-operations-domain/zones/operations-data-product-zone/assets/audit-data --format json >> secure_cmds

}

dp_res_ls() {
      task=${1:-customer}
      ext=${2:-.parquet}
      bucket=$(gcloud dataplex assets list --zone $LAKES/prod-$task-source-domain/zones/$task-curated-zone --format json | jq -r '.[]| select (.name|test("curated-data"))|.resourceSpec.name')
      echo "listing files in curated-zone bucket asset for $task ($bucket)"
      gsutil ls -r gs://$bucket | grep $ext 
}

curate() {
  [[ -f demo_assets ]] || assets > demo_assets
  echo TODO: update this when the APIs are ready and also add dataflow APIs for the time being
  [[ -z $network ]] && network=$(gcloud compute networks subnets list --filter="name=default" --format="value(selfLink)")

  for task in customer merchant transactions 
  do 
      echo 
      echo task  - create $task curation dataflow job
      echo name:curate-$task-raw-data
      echo lake:$task source domain
      echo job_args.source:$(grep $task-raw-data demo_assets)
      echo job_args.type:PARQUET
      echo job_args.dst:$(grep $task-curated-data demo_assets)
      sa=$task ; [[ $sa == "transactions" ]] && sa="cc-trans-sa"
      echo job_args.sa:"$(gcloud iam service-accounts list --format="(email)" | grep $sa)"
      echo job_args.network:$network
      echo
      echo TESTING: when the join is done you can test files are created in the zone with dp_res_ls $task

  done 

}

data_quality() {

  echo TODO: update this when the APIs are ready and also add dataflow APIs for the time being


  for task in customer merchant transactions 
  do 
      sa=${task}_sa
      echo 
      echo task  - $task data quality task 
      echo --------------------------------------
      echo lake:prod-${task}-source-domain
      echo name:dq-$task-data-quality-task
      echo job_args.dq_apec:${PROJECT_DATAGOV}_dataplex_process/${task}-source-configs/dq_${task}_gcs_data.yaml
      echo job_args.rsults_table:${PROJECT_DATAGOV}.central_dq_results
      echo job_args.table_name:dq_results
      echo $sa:${!sa}
      echo
      #echo TESTING: when the join is done you can test files are created in the zone with dp_res_ls $task

  done 

}

classify() {
  echo '# Task 1 - dlp SA access to data store via dlp.admin role'
  project_num=$(gcloud projects list --filter="${PROJECT_DATASTO}" --format="value(PROJECT_NUMBER)")
  gcloud projects add-iam-policy-binding ${PROJECT_DATASTO} --member="serviceAccount:service-${project_num}@dlp-api.iam.gserviceaccount.com" --role="roles/dlp.admin" 
  echo create dlp scan configuration in the UI create a new template
  echo "The lab suggest using: projects/mbdatagov-137194260/inspectTemplates/marsbank_dlp_template - but it does not seem to be accessible."
  echo send data profile to ${PROJECT_DATAGOV} central_dlp_data dlp_data_profiles

}

data_products() {
 move_data customer customers_data customer_refined_data customercustom
 move_data merchant merchants_data merchants_refined_data merchantcustom 
 move_data transactions auth_data pos_auth_refined_data transcustom
}



move_data() {
  zone=$1
  entity=$2
  ds=$3
  sql=${4}.sql
  sa=${zone}_sa

  gcloud dataplex tasks create $zone-curated-refined \
    --project=${PROJECT_DATAGOV} \
    --location=us-central1 \
    --vpc-sub-network-name=projects/${PROJECT_DATAGOV}/regions/us-central1/subnetworks/default \
    --lake=prod-$zone-source-domain \
    --trigger-type=ON_DEMAND \
    --execution-service-account=$(echo ${!sa} | sed s/serviceAccount://) \
    --spark-main-class="com.google.cloud.dataproc.templates.main.DataProcTemplate" \
    --spark-file-uris="gs://${PROJECT_DATAGOV}_dataplex_process/common/log4j-spark-driver-template.properties" \
    --container-image-java-jars="gs://${PROJECT_DATAGOV}_dataplex_process/common/dataproc-templates-1.0-SNAPSHOT.jar" \
    --execution-args=^::^TASK_ARGS="--template=DATAPLEXGCSTOBQ,\
        --templateProperty=project.id=${PROJECT_DATASTO},\
        --templateProperty=dataplex.gcs.bq.target.dataset=$ds,\
        --templateProperty=gcs.bigquery.temp.bucket.name=${PROJECT_DATAGOV}_dataplex_temp,\
        --templateProperty=dataplex.gcs.bq.save.mode=append,\
        --templateProperty=dataplex.gcs.bq.incremental.partition.copy=yes,\
        --dataplexEntity=projects/${PROJECT_DATAGOV}/locations/us-central1/lakes/prod-${zone}-source-domain/zones/${zone}-raw-zone/entities/${entity},\
        --partitionField=ingest_date,\
        --partitionType=DAY,\
        --targetTableName=${entity},\
        --customSqlGcsPath=gs://${PROJECT_DATAGOV}_dataplex_process/${zone}-source-configs/${sql}"
}

csv_to_parquet(){

  flex_template=gs://dataflow-templates-us-central1/latest/flex/Dataplex_File_Format_Conversion
  parms=""
  [[ -z $2 ]] && err_exit || sa="$2-sa@"
  [[ -z $3 ]] & err_exit || src="$3"
  [[ -z $4 ]] & err_exit || dst="$4"
  gcloud dataflow flex-template run $1
  subnetwork=$network --service-account-email=$sa --parameters="$parms"
  gcloud dataflow flex-template run curate-customer
  --template-file-gcs-location=$flex_template
  --subnetwork=$network --service-account-email=$sa --parameters="$parms" --
}

remove_composer() {
  composer_env=$(gcloud composer environments list --format="value(name)")
  [[ -n $composer_env ]]  && -q gcloud composer environments delete $composer_env
}


add_composer_tf() {
  # terraform apply + tain composer module + target setup
  popd oneclick/demo-gov/terraform/
  terraform taint module.composer.null_resource.dag_setup #make sure dags are copied
  terraform apply  -var project_id_governance=$PROJECT_DATAGOV -var project_id_storage=${PROJECT_DATASTO} -var ldap=edn -var user_ip_range=10.6.0.0/24
  #if that does not work, need to do the taint and then target...
  #terraform apply  -var project_id_governance=$PROJECT_DATAGOV -var project_id_storage=${PROJECT_DATASTO} -var ldap=edn -var user_ip_range=10.6.0.0/24 --target module.composer.null_resource.dag_setup
}

launch_local_airflow() {
  echo quick setup
}
