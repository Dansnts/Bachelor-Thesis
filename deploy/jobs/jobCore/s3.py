import os

# One client per process: creating a boto3 client loads the botocore service
# models, which is expensive in CPU and memory. The API learned it the hard
# way: one client per request pinned the pod at its CPU limit.
_client = None


def make_s3_client(read_timeout=30, retries=3, pool_connections=10):
    """Return the process-wide S3 client, creating it on the first call.

    Single S3 factory of the project: API, batch driver, workers, solo,
    segment and CLI all use it. boto3 clients are thread-safe, so one
    instance per process is enough. The first call fixes the configuration
    for the process; later calls return the cached client as-is.

    Arguments :
    read_timeout         seconds before a read on MinIO is abandoned
    retries              attempts on a failed request (1 = fail fast)
    pool_connections     max parallel connections kept in the pool
    """
    global _client
    if _client is not None:
        return _client

    import boto3
    import urllib3
    from botocore.client import Config

    # MinIO uses a self-signed certificate, so we connect with verify=False.
    # Silence the per-request InsecureRequestWarning that would flood the logs.
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    _client = boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID")
        or os.getenv(
            "AWS_ACCESS_KEY"
        ),  # accept both AWS_ACCESS_KEY and AWS_ACCESS_KEY_ID so we don't depend on the variable name.
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(
            connect_timeout=5,
            read_timeout=read_timeout,
            retries={"max_attempts": retries},
            max_pool_connections=pool_connections,
        ),
        verify=False,
    )
    return _client


def get_object_bytes(client, bucket, key):
    """Download one S3 object and return its raw bytes.

    Arguments :
    client               boto3 S3 client
    bucket               bucket holding the object
    key                  S3 key of the object
    """
    return client.get_object(Bucket=bucket, Key=key)["Body"].read()


def iter_keys(client, bucket, prefix):
    """Yield every object key under an S3 prefix, page by page.

    Single listing loop of the project: callers filter the keys they want
    (image extensions, .parquet, ...) instead of each rewriting the
    paginator dance.

    Arguments :
    client               boto3 S3 client
    bucket               bucket to scan
    prefix               prefix under which to list the objects
    """
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            yield obj["Key"]
