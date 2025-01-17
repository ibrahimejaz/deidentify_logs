#!/bin/bash

project_id=${1:-`gcloud config get-value core/project`}
if [ -z "${project_id}" ]
then
    echo "Pass project id as argument or set project using 'gcloud config set project'"
    exit 1
fi

container_uri=${2:-"gcr.io/minherz/log-deidentification-custom-image:with_sdk"}

echo "🏗️ Enabling Google APIs..."
gcloud --project ${project_id} services enable \
    compute.googleapis.com \
    pubsub.googleapis.com \
    dataflow.googleapis.com \
    dlp.googleapis.com

echo "📟 Preparing PubSub..."
pubsub_topic=`gcloud --project ${project_id} pubsub topics describe log_ingestion_topic --format="value(name)"`
if [ -z "$pubsub_topic" ]
then
    gcloud --project=${project_id} pubsub topics create log_ingestion_topic
    gcloud --project=${project_id} pubsub subscriptions create log_ingestion_subscr --topic=log_ingestion_topic
fi

echo "🚰 Configuring export sink..."
export_sink_sa=`gcloud --project ${project_id} logging sinks describe log-with-pii-sink --format="value(writerIdentity)"`
if [ -z "$export_sink_sa" ]
then
    pubsub_topic="projects/${project_id}/topics/log_ingestion_topic"
    logname="projects/${project_id}/logs/logs-with-pii" 
    gcloud --project=${project_id} logging sinks create log-with-pii-sink "pubsub.googleapis.com/${pubsub_topic}" \
        --log-filter="logName=${logname}"
    cat > policy.yml <<EOF
bindings:
- members:
  - ${export_sink_sa}
  role: roles/pubsub.publisher
EOF
    gcloud --project=${project_id} pubsub topics set-iam-policy log_ingestion_topic policy.yaml --quiet
fi

echo "🔦 Deploy Dataflow pipeline..."
bucket_name="gs://${project_id}-example-bucket"
gsutil list ${bucket_name}
if [ $? == 1 ]
then
    gsutil mb ${bucket_name}
fi
pip3 install wheel apache_beam[gcp] google-cloud-logging
python3 deidentify.py \
   --runner DataflowRunner \
   --experiments=use_runner_v2 \
   --sdk_container_image=$container_uri \
   --region us-central1 \
   --project ${project_id} \
   --temp_location "${bucket_name}/temp" \
   --input-pubsub log_ingestion_subscr \
   --log-id no-pii-logs
