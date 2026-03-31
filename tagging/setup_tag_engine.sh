# Copyright 2026 Google, LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# This script executes the scripts to deploy and configure tag engine.

# Environment variables
pushd ../
source environment-variables.sh
popd

# Clone the tag engine repo
git clone -b dataplex --single-branch https://github.com/GoogleCloudPlatform/datacatalog-tag-engine.git tag_engine_temp

# Remove mappings file
rm tag_engine_temp/migrate/mappings.yaml

# Enable required APIs
gcloud config set project $TAG_ENGINE_PROJECT
gcloud services enable iam.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
gcloud services enable artifactregistry.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable cloudtasks.googleapis.com
gcloud services enable firestore.googleapis.com

# Create Cloud Tasks queues
gcloud tasks queues create tag-engine-injector-queue \
--location=$TAG_ENGINE_REGION --max-attempts=2 --max-concurrent-dispatches=100
gcloud tasks queues create tag-engine-work-queue \
--location=$TAG_ENGINE_REGION --max-attempts=2 --max-concurrent-dispatches=100

# Create Firestore database and indexes
gcloud firestore databases create \
--database=tag-engine-db \
--project=$TAG_ENGINE_PROJECT \
--location=$TAG_ENGINE_REGION
pip install google-cloud-firestore
pushd tag_engine_temp/deploy
python create_indexes.py $TAG_ENGINE_PROJECT tag-engine-db
popd

# Grant required roles to Cloud Run and Tag Creator service accounts
gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/logging.viewer

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/bigquery.jobUser

gcloud projects add-iam-policy-binding $PROJECT_ID_DATA \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/dataplex.aspectTypeUser

gcloud projects add-iam-policy-binding $PROJECT_ID_DATA \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/dataplex.catalogEditor

gcloud projects add-iam-policy-binding $PROJECT_ID_DATA \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/dataplex.catalogViewer

gcloud projects add-iam-policy-binding $BIGQUERY_PROJECT \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/bigquery.dataEditor

gcloud projects add-iam-policy-binding $BIGQUERY_PROJECT \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=roles/bigquery.metadataViewer

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/cloudtasks.enqueuer

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/cloudtasks.taskRunner

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/datastore.user

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/datastore.indexAdmin

gcloud projects add-iam-policy-binding $TAG_ENGINE_PROJECT \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/run.invoker

gcloud iam service-accounts add-iam-policy-binding $CLOUD_RUN_SA \
--member=serviceAccount:$CLOUD_RUN_SA \
--role roles/iam.serviceAccountUser \
--project $TAG_ENGINE_PROJECT

gcloud iam service-accounts add-iam-policy-binding $TAG_CREATOR_SA \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/iam.serviceAccountUser \
--project $PROJECT_ID_GOV

gcloud iam service-accounts add-iam-policy-binding $TAG_CREATOR_SA \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/iam.serviceAccountViewer \
--project $PROJECT_ID_GOV

gcloud iam service-accounts add-iam-policy-binding $TAG_CREATOR_SA \
--member=serviceAccount:$CLOUD_RUN_SA \
--role=roles/iam.serviceAccountTokenCreator \
--project $PROJECT_ID_GOV

# Roles for creating policy tags
gcloud iam roles create BigQuerySchemaUpdate \
 --project $BIGQUERY_PROJECT \
 --title BigQuerySchemaUpdate \
 --description "Update table schema with policy tags" \
 --permissions bigquery.tables.setCategory

gcloud projects add-iam-policy-binding $BIGQUERY_PROJECT \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=projects/$BIGQUERY_PROJECT/roles/BigQuerySchemaUpdate

gcloud iam roles create PolicyTagReader \
--project $PROJECT_ID_DATA \
--title PolicyTagReader \
--description "Read Policy Tag Taxonomy" \
--permissions datacatalog.taxonomies.get,datacatalog.taxonomies.list

gcloud projects add-iam-policy-binding $PROJECT_ID_DATA \
--member=serviceAccount:$TAG_CREATOR_SA \
--role=projects/$PROJECT_ID_DATA/roles/PolicyTagReader

# Create tagengine.ini
cat <<EOF > tag_engine_temp/tagengine.ini
[DEFAULT]
TAG_ENGINE_SA = $CLOUD_RUN_SA
TAG_CREATOR_SA = $TAG_CREATOR_SA
TAG_ENGINE_PROJECT = $TAG_ENGINE_PROJECT
TAG_ENGINE_REGION = $TAG_ENGINE_REGION
FIRESTORE_DB = tag-engine-db
BIGQUERY_REGION = $REGION
INJECTOR_QUEUE = tag-engine-injector-queue
WORK_QUEUE = tag-engine-work-queue
ENABLE_TAG_HISTORY = true
TAG_HISTORY_PROJECT = $PROJECT_ID_GOV
TAG_HISTORY_DATASET = $TAG_HISTORY_BIGQUERY_DATASET
ENABLE_AUTH = false
EOF

# Deploy Cloud Run service
gcloud run deploy tag-engine-api \
--source tag_engine_temp \
--platform managed \
--project $TAG_ENGINE_PROJECT \
--region $TAG_ENGINE_REGION \
--no-allow-unauthenticated \
--ingress=all \
--memory=4G \
--timeout=60m \
--service-account=$CLOUD_RUN_SA \
--quiet

gcloud config set run/region $REGION
export TAG_ENGINE_URL=`gcloud run services describe tag-engine-api --format="value(status.url)"`
gcloud run services update tag-engine-api --set-env-vars SERVICE_URL=$TAG_ENGINE_URL

# Configure tag engine
# source tag_engine_configs/create_configs_run_jobs.sh

# Remove cloned repo
rm -rf tag_engine_temp