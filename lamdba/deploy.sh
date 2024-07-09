#!/bin/bash

# Processing Layers

cd layers
while IFS= read -r line # iterating line by line on layers.yaml to find the layers to be deployed
do
    if [[ $line == "-"* ]];
    then
        layer_name=$(echo "${line#*-}" | tr -d ' ') # taking everything that comes afeter "-" in the line and stripping extra spaces
        echo "processing lambda layer: $layer_name"
        (cd $layer_name && zip -r "../$layer_name.zip" ./*;) # creating zip file with the layer libraries

        echo "creating lambda layer: $layer_name"
        # deploying layer with zip file
        aws lambda publish-layer-version --layer-name $layer_name --zip-file fileb://$layer_name.zip --compatible-runtimes python3.10 python3.11 python3.12 1>/dev/null
    fi
done < ./layers.yaml
cd ..
echo "completed processing lambda layers"

# Processing lambda functions

cd functions
for dir in lambda-*.prm; do # iterating all the prm files for each lambda functions
    latest_layer_arn=""
    lambda_prm=$(cat $dir)
    for line in $lambda_prm; # iterating all lines of prm file to get the parameters for lambda function
    do
        prm_arr=(${line//=/ })
        case "${prm_arr[0]}" in
            function_name)
                function_name=${prm_arr[1]}
                ;;
            path)
                function_path=${prm_arr[1]}
                ;;
            role)
                function_role_arn="--role ${prm_arr[1]}"
                ;;
            layer)
                layer_name=${prm_arr[1]}
                latest_layer_arn=$(aws lambda list-layer-versions --layer-name $layer_name --output text --query 'max_by(LayerVersions, &Version).LayerVersionArn')
                latest_layer_arn="--layer $latest_layer_arn"
                ;;
            *)
                extra=${prm_arr[1]}
                ;;
        esac
    done
    subnet_ids="subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f"
    security_grps="sg-004c1f8cc363fdd90"
    echo "Processing function: $function_name =================================================================";

    curr_lambda=$(aws lambda get-function --function-name $function_name --region ap-south-1 2>/dev/null) # checking with the function name to find if the function already exists
    echo "curr_lambda $curr_lambda"
    if [ "$curr_lambda" != "" ]; then
        echo "Lambda function $function_name already exists, updating..."

        live_lambda_url=$(echo $curr_lambda | python -c 'import json,sys;print(json.load(sys.stdin)["Code"]["Location"])') # getting the code zip file url from the get-function command data
        live_lambda_role=$(echo $curr_lambda | python -c 'import json,sys;print(json.load(sys.stdin)["Configuration"]["Role"])') # getting the code IAM role the get-function command data
        live_layer_arn=$(echo $curr_lambda | python -c 'import json,sys;print(json.load(sys.stdin)["Configuration"]["Layers"]["Arn"]) if "Layers" in json.load(sys.stdin)["Configuration"] else print("")')
        echo "live_layer_arn $live_layer_arn"

        # downloading the current code zip file and unzipping it
        curl -o ${function_name}_live.zip $live_lambda_url 1>/dev/null
        unzip -d ${function_name}_live/ ${function_name}_live.zip 1>/dev/null

        # calculating md5sum for each file and storing them in txt files sorted by file name
        find $function_path/ -type f -exec md5sum {} + | sort -k 2 | cut -f1 -d" " > git_func.txt
        find ${function_name}_live/ -type f -exec md5sum {} + | sort -k 2 | cut -f1 -d" " > live_func.txt
        DIFF=$(diff -u git_func.txt live_func.txt) # getting the difference for each directory

        if [ "$DIFF" != "" ] ; then
            # if there is difference in both the directories then update the current function code
            echo "Zipping contents of $function_path";
            (cd $function_path && zip -r "../$function_name.zip" ./*;)  # Zip the contents of each subdirectory
            aws lambda update-function-configuration --function-name $function_name $latest_layer_arn --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=$subnet_ids,SecurityGroupIds=$security_grps 1>/dev/null
            aws lambda wait function-updated --function-name $function_name
            aws lambda update-function-code --function-name $function_name --zip-file fileb://$function_name.zip 1>/dev/null
        else
            echo "no change found in code for lambda function $function_name"
        fi
    else
        echo "Zipping contents of $function_path";
        (cd $function_path && zip -r "../$function_name.zip" ./*;)  # Zip the contents of each subdirectory
        echo "Lambda function $function_name does not exist, creating..."
        aws lambda create-function --function-name $function_name $function_role_arn --runtime python3.11 $latest_layer_arn --handler lambda_function.lambda_handler --zip-file fileb://$function_name.zip --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f,SecurityGroupIds=sg-004c1f8cc363fdd90 1>/dev/null
    fi
done