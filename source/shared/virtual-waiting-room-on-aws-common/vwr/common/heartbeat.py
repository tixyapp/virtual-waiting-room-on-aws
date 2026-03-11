# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""
Heartbeat helpers using a Redis sorted set.

Key: "heartbeats" (bare string — no EVENT_ID prefix; one ElastiCache cluster per event)
Score: Unix timestamp of last ping
Member: request_id
"""

import time

HEARTBEAT_KEY = "heartbeats"


def record_heartbeat(rc, request_id: str) -> None:
    """Upsert the user's last-seen timestamp (score) in the sorted set."""
    rc.zadd(HEARTBEAT_KEY, {request_id: int(time.time())})


def get_abandoned(rc, stale_threshold_seconds: int = 90) -> list:
    """Return request_ids whose last ping is older than stale_threshold_seconds."""
    cutoff = int(time.time()) - stale_threshold_seconds
    return rc.zrangebyscore(HEARTBEAT_KEY, 0, cutoff)


def remove_heartbeat(rc, request_id: str) -> None:
    """Remove a request_id from the sorted set (token issued or abandoned)."""
    rc.zrem(HEARTBEAT_KEY, request_id)


def clear_all_heartbeats(rc) -> None:
    """Delete the entire heartbeats sorted set. Called by reset_initial_state between events."""
    rc.delete(HEARTBEAT_KEY)
