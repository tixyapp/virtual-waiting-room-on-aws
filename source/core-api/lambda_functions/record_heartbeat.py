# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
This module is the record_heartbeat API handler.
It records a liveness ping from a user in the waiting room queue.
Upserts the user's request_id into a Redis sorted set with the current
Unix timestamp as the score. The detect_abandoned Lambda uses this set
to identify users who have silently left the queue.
"""

import json
import os
import boto3
from botocore import config
from vwr.common.redis_client import get_redis_client
from vwr.common.validate import is_valid_rid
from vwr.common.sanitize import deep_clean
from vwr.common.heartbeat import record_heartbeat

EVENT_ID = os.environ["EVENT_ID"]
SECRET_NAME_PREFIX = os.environ["STACK_NAME"]
SOLUTION_ID = os.environ["SOLUTION_ID"]

user_agent_extra = {"user_agent_extra": SOLUTION_ID}
user_config = config.Config(**user_agent_extra)
boto_session = boto3.session.Session()
region = boto_session.region_name
secrets_client = boto3.client(
    "secretsmanager",
    config=user_config,
    endpoint_url=f"https://secretsmanager.{region}.amazonaws.com",
)
rc = get_redis_client(secrets_client, SECRET_NAME_PREFIX)

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
}


def lambda_handler(event, _):
    """
    This function is the entry handler for Lambda.
    """

    print(event)
    body = json.loads(event.get("body", "{}"))
    request_id = deep_clean(body.get("request_id", ""))
    client_event_id = deep_clean(body.get("event_id", ""))

    if client_event_id != EVENT_ID or not is_valid_rid(request_id):
        return {
            "statusCode": 400,
            "headers": HEADERS,
            "body": json.dumps({"error": "Invalid event or request ID"}),
        }

    record_heartbeat(rc, request_id)

    return {
        "statusCode": 200,
        "headers": HEADERS,
        "body": json.dumps({"ok": True}),
    }
