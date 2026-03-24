output=$(bq show --location=$REGION --project_id=$PROJECT_ID_GOV --connection remote-function-connection)
echo "$output"
properties=$(echo "$output" | grep "remote function connection" | awk -F'   ' '{print $NF}')
service_account_id=$(echo "$properties" | python3 -c "import sys, json; print(json.load(sys.stdin)['serviceAccountId'])")
service_account_string="$service_account_id"

# Replace placeholders and pipe the SQL to bq to create the remote function.
sed "s/PROJECT_ID_GOV/$PROJECT_ID_GOV/g; s/REGION/$REGION/g" sql/create_function.sql | bq query --use_legacy_sql=false
	
gcloud functions add-invoker-policy-binding get_bytes_transferred \
	--member="serviceAccount:$service_account_string"
	
#select `sdw-data-gov-b1927e-dd69`.remote_functions.get_bytes_transferred('bytes', 'sdw-conf-b1927e-bcc1', 'crm', 'AddAcct');
#select `sdw-data-gov-b1927e-dd69`.remote_functions.get_bytes_transferred('cost', 'sdw-conf-b1927e-bcc1', 'crm', 'NewCust');
