#!/bin/bash
cd layers
for dir in ./*; do
    # layer_name=${dir:2}
    layer_name=$(echo $dir | awk -F"/" ' { print $2 } ')
    echo "processing lambda layer: $layer_name"
    (cd $dir && zip -r "../$layer_name.zip" ./*;)

    latest_layer_arn=$(aws lambda list-layer-versions --layer-name $layer_name --query 'LayerVersions[0].LayerVersionArn')
    latest_layer_arn="${latest_layer_arn//\"/}"
    layer_sha=$(aws lambda get-layer-version-by-arn --arn $latest_layer_arn --query 'Content.CodeSha256')
    current_sha=$(sha256sum $layer_name.zip)
    echo "Layer sha code: $layer_sha"
    echo "Current sha code: $current_sha"
    echo "creating lambda layer: $layer_name"
    layer_arn=$(aws lambda publish-layer-version --layer-name $layer_name --zip-file fileb://$layer_name.zip --compatible-runtimes python3.10 python3.11 python3.12 | python -c 'import json,sys;obj=json.load(sys.stdin);print(obj["LayerVersionArn"])')
    echo "Layer version ARN: $layer_arn"
done
cd ..
echo "completed processing lambda layers"
cd functions
for dir in lambda-*.prm; do
    echo "process started $dir"
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
                function_role_arn=${prm_arr[1]}
                ;;
            *)
                extra=${prm_arr[1]}
                ;;
        esac
    done                
    echo "Processing function: $function_name";

    echo "Zipping contents of $function_path";
    (cd $function_path && zip -r "../$function_name.zip" ./*;)  # Zip the contents of each subdirectory
    if aws lambda get-function --function-name $function_name --region ap-south-1 2>/dev/null; then
        echo "Lambda function $function_name already exists, updating..."
        aws lambda update-function-configuration --function-name $function_name --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f,SecurityGroupIds=sg-004c1f8cc363fdd90
        aws lambda wait function-updated --function-name $function_name
        aws lambda update-function-code --function-name $function_name --zip-file fileb://$function_name.zip
    else
        echo "Lambda function $function_name does not exist, creating..."
        aws lambda create-function --function-name $function_name --role $function_role_arn --runtime python3.11 --handler lambda_function.lambda_handler --zip-file fileb://$function_name.zip --vpc-config Ipv6AllowedForDualStack=false,SubnetIds=subnet-0256b46d74a09fa77,subnet-0aafae4a32135023f,SecurityGroupIds=sg-004c1f8cc363fdd90
    fi
done