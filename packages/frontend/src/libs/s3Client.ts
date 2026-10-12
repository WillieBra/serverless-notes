import { S3Client } from "@aws-sdk/client-s3";
import { fromCognitoIdentityPool } from "@aws-sdk/credential-provider-cognito-identity";
import { CognitoIdentityClient } from "@aws-sdk/client-cognito-identity";
import { IDENTITY_POOL_ID, REGION, LOCALSTACK_ENDPOINT } from "../config";

const s3Client = new S3Client({
  region: REGION,
  endpoint: LOCALSTACK_ENDPOINT,
  forcePathStyle: Boolean(LOCALSTACK_ENDPOINT),
  credentials: fromCognitoIdentityPool({
    client: new CognitoIdentityClient({
      region: REGION,
      endpoint: LOCALSTACK_ENDPOINT,
    }),
    identityPoolId: IDENTITY_POOL_ID,
  }),
});

export { s3Client };
