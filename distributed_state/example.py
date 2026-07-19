from dataclasses import dataclass
from collections import deque
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
import threading
import random
import time


#
# Simulated opportunity graph
#
GRAPH = {
    ("TaskA", "A1"): [("TaskA", "A2"), ("TaskA", "A3")],
    ("TaskA", "A2"): [],
    ("TaskA", "A3"): [("TaskA", "A4")],
    ("TaskA", "A4"): [],

    ("TaskB", "B1"): [("TaskB", "B2"), ("TaskB", "B3")],
    ("TaskB", "B2"): [],
    ("TaskB", "B3"): [("TaskB", "B4"), ("TaskB", "B5")],
    ("TaskB", "B4"): [],
    ("TaskB", "B5"): [],
}


@dataclass
class PipelineState:
    outstanding: int = 0
    created: int = 0
    completed: int = 0
    status: str = "RUNNING"


class OpportunityAggregator:

    def __init__(self):
        self.lock = threading.Lock()
        self.tasks = {}

    def _state(self, task_id):

        if task_id not in self.tasks:
            print(f"\n*** First time seeing {task_id}. Creating state. ***")
            self.tasks[task_id] = PipelineState()

        return self.tasks[task_id]

    def opportunity_created(self, task_id, opportunity_id):

        with self.lock:

            state = self._state(task_id)

            state.outstanding += 1
            state.created += 1
            state.status = "RUNNING"

            print(f"[CREATED ] {task_id} -> {opportunity_id}")
            self.print_task(task_id)

    def opportunity_completed(self, task_id, opportunity_id):

        with self.lock:

            state = self._state(task_id)

            state.outstanding -= 1
            state.completed += 1

            if state.outstanding == 0:
                state.status = "COMPLETE"

            print(f"[COMPLETE] {task_id} -> {opportunity_id}")
            self.print_task(task_id)

    def print_task(self, task_id):

        s = self.tasks[task_id]

        print(
            f"    Outstanding={s.outstanding} "
            f"Created={s.created} "
            f"Completed={s.completed} "
            f"Status={s.status}"
        )

    def print_all(self):

        print("\n========== AGGREGATOR ==========")

        for task_id in sorted(self.tasks):

            s = self.tasks[task_id]

            print(
                f"{task_id}: "
                f"Outstanding={s.outstanding} "
                f"Created={s.created} "
                f"Completed={s.completed} "
                f"Status={s.status}"
            )

        print("===============================\n")


def lambda_handler(task_id, opportunity_id):

    work = random.uniform(0.5, 2.0)

    print(f"Lambda running {task_id}:{opportunity_id} ({work:.1f}s)")

    time.sleep(work)

    children = GRAPH.get((task_id, opportunity_id), [])

    return task_id, opportunity_id, children


def main():

    aggregator = OpportunityAggregator()

    queue = deque()

    #
    # Initial root opportunities
    #
    roots = [
        ("TaskA", "A1"),
        ("TaskB", "B1")
    ]

    #
    # Root opportunities are created
    #
    for task_id, opp_id in roots:
        aggregator.opportunity_created(task_id, opp_id)
        queue.append((task_id, opp_id))

    executor = ThreadPoolExecutor(max_workers=3)

    running = {}

    while queue or running:

        #
        # Launch work
        #
        while queue and len(running) < 3:

            task_id, opp_id = queue.popleft()

            future = executor.submit(
                lambda_handler,
                task_id,
                opp_id
            )

            running[future] = (task_id, opp_id)

        #
        # Wait until one Lambda finishes
        #
        done, _ = wait(
            running.keys(),
            return_when=FIRST_COMPLETED
        )

        for future in done:

            running.pop(future)

            task_id, opp_id, children = future.result()

            #
            # Child opportunities are CREATED
            #
            for child_task, child_opp in children:

                aggregator.opportunity_created(
                    child_task,
                    child_opp
                )

                queue.append((child_task, child_opp))

            #
            # Parent opportunity COMPLETES
            #
            aggregator.opportunity_completed(
                task_id,
                opp_id
            )

            aggregator.print_all()

    executor.shutdown()

    print("\nAll processing complete.")


if __name__ == "__main__":
    main()