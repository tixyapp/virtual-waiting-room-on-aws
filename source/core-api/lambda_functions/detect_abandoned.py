# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
This module detects users who have silently abandoned the queue
(e.g. closed the browser tab) by checking whose heartbeat timestamps
have gone stale in the Redis sorted set.

Abandoned request_ids are published to the MaxSizeInletSns SNS topic
as an "abandoned" list. MaxSizeInlet handles calling /update_session
(status=-1) and /increment_serving_counter via the Private API,
freeing those queue slots for the next users.

Triggered by EventBridge on a rate(1 minute) schedule.
"""

import json
import os
import boto3
from botocore import config
from vwr.common.redis_client import get_redis_client
from vwr.common.heartbeat import get_abandoned, remove_heartbeat

EVENT_ID = os.environ["EVENT_ID"]
SECRET_NAME_PREFIX = os.environ["STACK_NAME"]
SOLUTION_ID = os.environ["SOLUTION_ID"]
SNS_TOPIC_ARN = os.environ["SESSION_EVENTS_SNS_ARN"]
STALE_THRESHOLD = int(os.environ.get("STALE_THRESHOLD_SECONDS", "90"))

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
sns_client = boto3.client("sns", config=user_config)


def lambda_handler(event, _):
    """
    This function is the entry handler for Lambda.
    """

    print(event)
    abandoned = get_abandoned(rc, STALE_THRESHOLD)

    if not abandoned:
        print("detect_abandoned: no stale heartbeats found")
        return {"processed": 0}

    # Remove stale entries from the sorted set before publishing,
    # so a slow SNS delivery does not cause double-processing on the next run.
    for rid in abandoned:
        remove_heartbeat(rc, rid)

    sns_client.publish(
        TopicArn=SNS_TOPIC_ARN,
        Message=json.dumps({"abandoned": abandoned}),
    )

    print(f"detect_abandoned: published {len(abandoned)} abandoned request_ids to SNS")
    return {"processed": len(abandoned)}
