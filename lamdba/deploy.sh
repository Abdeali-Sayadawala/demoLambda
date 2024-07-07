#!/bin/bash
cd layers
while IFS= read -r line
do
    if [[ $line == "-"* ]];
    then
        echo "line $line"
        layer_name=$(echo "${line#*-}" | tr -d ' ')
        echo "processing lambda layer: $layer_name"
        (cd $layer_name && zip -r "../$layer_name.zip" ./*;)

        echo "creating lambda layer: $layer_name"
        aws lambda publish-layer-version --layer-name $layer_name --zip-file fileb://$layer_name.zip --compatible-runtimes python3.10 python3.11 python3.12 1>/dev/null
    fi
done < ./layers.yaml
cd ..
echo "completed processing lambda layers"


cd functions
for dir in lambda-*.prm; do
    latest_layer_arn=""
    lambda_prm=$(cat $dir)
    for line in $lambda_prm;
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
    echo "Processing function: $function_name";

    if aws lambda get-function --function-name $function_name --region ap-south-1 2>/dev/null; then
        aws lambda get-function --function-name $function_name --region ap-south-1 --query 'Code.Location' | xargs curl -o ${function_name}_live.zip
        unzip -d ${function_name}_live/ ${function_name}_live.zip 1>/dev/null
        find $function_path/ -type f -exec md5sum {} + | sort -k 2 | cut -f1 -d" " > git_func.txt
        find ${function_name}_live/ -type f -exec md5sum {} + | sort -k 2 | cut -f1 -d" " > live_func.txt
        DIFF=$(diff -u git_func.txt live_func.txt)

        if [ "$DIFF" != "" ] ; then
            echo "Lambda function $function_name already exists, updating..."
            aws lambda update-function-configuration --function-name $function_name $latest_layer_arn --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f,SecurityGroupIds=sg-004c1f8cc363fdd90 1>/dev/null
            aws lambda wait function-updated --function-name $function_name
            aws lambda update-function-code --function-name $function_name --zip-file fileb://$function_name.zip 1>/dev/null
        else
            echo "no change found in code for lambda function $function_name"
        fi
    else
        echo "Lambda function $function_name does not exist, creating..."
        aws lambda create-function --function-name $function_name $function_role_arn --runtime python3.11 $latest_layer_arn --handler lambda_function.lambda_handler --zip-file fileb://$function_name.zip --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f,SecurityGroupIds=sg-004c1f8cc363fdd90 1>/dev/null
    fi
    
done