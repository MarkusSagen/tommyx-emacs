import random
from enum import Enum

from data_structure import *
import util


def used_ratio_to_etr(used_ratio):
    return (
        math.inf
        if used_ratio <= 0.0
        else (1.0 / used_ratio) - 1.0
    )


def etr_to_used_ratio(etr):
    return (
        0.0
        if etr == math.inf
        else 1.0 / (1.0 + etr)
    )


def tuple_sampler_key_function(x):
    return x[0]


class TaskIndexFinder(object):
    '''
    Helper container that stores all active task index per task id. 
    This is used to support multiple tasks (different task index)
    for the same task id.
    '''

    def __init__(self):
        self._data = {}

    def _ensure_exists(self, task_id):
        if task_id not in self._data:
            self._data[task_id] = set()

    def add(self, task_id, task_index):
        self._ensure_exists(task_id)
        self._data[task_id].add(task_index)

    def remove(self, task_id, task_index):
        self._ensure_exists(task_id)
        self._data[task_id].remove(task_index)

    def get_task_indices(self, task_id):
        self._ensure_exists(task_id)
        return self._data[task_id]


class ScheduleFiller(object):

    def __init__(self, schedule, direction):
        self.initialize(schedule, direction)

    def initialize(self, schedule, direction):
        self.schedule = schedule

        self.delta = None
        self.get_schedule_date = None
        self.is_before = None

        if direction == FillDirection.EARLY:
            self.delta = 1
            self.get_schedule_date = ScheduleFiller._get_schedule_date_early
            self.is_before = ScheduleFiller._is_before_early

        elif direction == FillDirection.LATE:
            self.delta = -1
            self.get_schedule_date = ScheduleFiller._get_schedule_date_late
            self.is_before = ScheduleFiller._is_before_late

        else:
            raise ValueError()

    def _get_schedule_date_early(date):
        return date

    def _get_schedule_date_late(date):
        return date.add_days(-1)

    def fill(self, task_id, amount, date_from, date_to, weakness=SessionWeaknessEnum.WEAK, session_type=SessionTypeEnum.TASK, task_index=0, total_amount=0):
        '''
        Fill task_id with amount from 00:00 of date_from to 00:00 of date_to.
        The concept of "before" is determined by fill direction,
        which means date_from should be later than date_to if direction is reversed.
        '''
        if self.is_before(date_to, date_from):
            raise ValueError()

        date = date_from
        amount_filled = 0

        # while date < date_to
        while self.is_before(date, date_to):
            if amount <= 0:
                break

            schedule_date = self.get_schedule_date(date)
            free_time = self.schedule.get_free_time(schedule_date)
            session_amount = min(amount, free_time)
            if session_amount > 0:
                amount -= session_amount
                total_amount -= session_amount
                amount_filled += session_amount
                session = Session()
                session.id.value = task_id
                session.amount.value = session_amount
                session.type.value = session_type
                session.weakness.value = weakness
                if total_amount >= 0:
                    session.to_finish = Duration(total_amount)

                session.task_index = TaskIndex(task_index)
                self.schedule.add_session(schedule_date, session)

            date = date.add_days(self.delta)

        return amount_filled

    def _is_before_early(date1, date2):
        return date1 < date2

    def _is_before_late(date1, date2):
        return date1 > date2


class GreedySchedulingQueue(object):
    '''
    A priority queue for greedy scheduling.
    Data must be unique and hashable.
    '''

    def __init__(self, descending=False):
        self.heap = []
        self.indices = {}
        self.comp = None
        if descending:
            self.comp = GreedySchedulingQueue._comp_descending

        else:
            self.comp = GreedySchedulingQueue._comp_ascending

    def _comp_ascending(a, b):
        return a < b

    def _comp_descending(a, b):
        return b < a

    def clear(self):
        '''
        Clears the queue.
        '''

        self.heap = []
        self.indices = {}

    def is_empty(self):
        return len(self.heap) == 0

    def top(self):
        '''
        Returns the data in the queue with the highest priority.
        '''
        return self.heap[0][0]

    def add(self, data, priority):
        '''
        Add data with given priority.
        '''
        if data in self.indices:
            raise ValueError()

        self.heap.append((data, priority))
        self.indices[data] = len(self.heap) - 1
        self._float_up(len(self.heap) - 1)

    def delete(self, data):
        if data not in self.indices:
            return

        index = self.indices[data]
        old_priority = self.heap[index][1]
        new_data, priority = self.heap[len(self.heap) - 1]
        self.indices[new_data] = index
        self.heap[index] = (new_data, priority)

        self.heap.pop()
        del self.indices[data]

        if index == len(self.heap):
            return

        # if priority > old_priority:
        if self.comp(old_priority, priority):
            self._float_up(index)

        else:
            self._float_down(index)

    def _float_down(self, i):
        '''
        Pushes the i-th entry downward on the heap when necessary.
        '''

        i_value, i_priority = self.heap[i]
        j = i

        while j < len(self.heap) - 1:
            l = 2 * i + 1
            r = 2 * i + 2

            # if l < len(self.data) and self.data[l][1] > self.data[j][1]:
            if l < len(self.heap) and self.comp(self.heap[j][1], self.heap[l][1]):
                j = l

            # if r < len(self.data) and self.data[r][1] > self.data[j][1]:
            if r < len(self.heap) and self.comp(self.heap[j][1], self.heap[r][1]):
                j = r

            if j == i:
                break

            self.indices[self.heap[j][0]] = i
            self.indices[i_value] = j
            self.heap[i], self.heap[j] = self.heap[j], self.heap[i]

            i = j

    def _float_up(self, i):
        '''
        Pushes the i-th entry upward on the heap when necessary.
        '''
        i_value, i_priority = self.heap[i]
        j = i

        while j > 0:
            j = (i - 1) // 2

            # if i_priority <= self.data[j][1]:
            if not self.comp(self.heap[j][1], i_priority):
                break

            self.indices[self.heap[j][0]] = i
            self.indices[i_value] = j
            self.heap[i], self.heap[j] = self.heap[j], self.heap[i]

            i = j


class DateIterator(object):

    def __init__(self, start, end, direction):
        if start > end:
            raise ValueError()

        # The next date to return.
        self.date = None
        self.delta = None
        self.start = start
        self.end = end
        self.has_next = None

        if direction == FillDirection.EARLY:
            self.date = start
            self.delta = 1
            self.has_next = self._has_next_early

        elif direction == FillDirection.LATE:
            self.date = end
            self.delta = -1
            self.has_next = self._has_next_late

        else:
            raise ValueError()

    def get_next(self):
        '''
        Return next value, but do not increment.
        '''
        return self.date

    def next(self):
        if not self.has_next():
            return None  # Can be optimized.

        date = self.date
        self.date = self.date.add_days(self.delta)
        return date

    def _has_next_early(self):
        return self.date <= self.end

    def _has_next_late(self):
        return self.date >= self.start


class TaskEventType(Enum):
    TASK_START = 0
    TASK_END = 1


class TaskEvent(object):
    '''
    Describes a point in time (00:00 of self.date) where an event occur for a task.
    Can either be TaskEventType.TASK_START or TaskEventType.TASK_END.

    Note that TASK_START may be the deadline of task if scheduling backward.
    '''

    def __init__(self, task_index, task_id, date, opposite_date, event_type):
        self.task_index = task_index
        self.task_id = task_id
        self.date = date
        self.opposite_date = opposite_date
        self.event_type = event_type

    def __lt__(self, other):
        return self.date < other.date


class TaskEventsIterator(object):

    def __init__(self, tasks, start, end, direction, tasks_mask=None):
        '''
        TODO
        Start and end represents 00:00 of that day.
        '''
        if start is not None and end is not None and start > end:
            raise ValueError()

        self.task_events = []

        self.direction = direction

        # Points to next event to be read.
        self.index = 0

        def safe_add_1_day(date):
            if date.is_max():
                return date

            return date.add_days(1)

        for i in range(len(tasks)):
            if tasks_mask is not None and not tasks_mask[i]:
                continue

            task = tasks[i]
            self.task_events.append(TaskEvent(
                i,
                task.id.value,
                util.clamp(task.start, start, end),
                safe_add_1_day(util.clamp(task.end, start, end)),
                TaskEventType.TASK_START
                if direction == FillDirection.EARLY else TaskEventType.TASK_END
            ))
            self.task_events.append(TaskEvent(
                i,
                task.id.value,
                safe_add_1_day(util.clamp(task.end, start, end)),
                util.clamp(task.start, start, end),
                TaskEventType.TASK_END
                if direction == FillDirection.EARLY else TaskEventType.TASK_START
            ))

        if direction == FillDirection.EARLY:
            self.task_events.sort(key=lambda x: x.date)
            self.is_before = TaskEventsIterator._is_before_early

        elif direction == FillDirection.LATE:
            self.task_events.sort(key=lambda x: x.date, reverse=True)
            self.is_before = TaskEventsIterator._is_before_late

        else:
            raise ValueError()

    def read_event_to(self, date):
        '''
        Return the next unread event before and including at 00:00 of date.
        The concept of "before" is determined by fill direction.
        '''

        if self.index < 0 or self.index >= len(self.task_events):
            return None

        next_event = self.task_events[self.index]
        # if next_event.date <= date
        if not self.is_before(date, next_event.date):
            self.index += 1
            return next_event

        return None

    def read_next_event(self):
        if self.index < 0 or self.index >= len(self.task_events):
            return None

        next_event = self.task_events[self.index]
        self.index += 1
        return next_event

    def _is_before_early(date1, date2):
        return date1 < date2

    def _is_before_late(date1, date2):
        return date1 > date2


class Sampler(object):
    '''
    TODO: Needs testing.
    '''

    def __init__(self, seed=None, key=None):
        if seed is not None:
            self.random = random.Random(seed)

        else:
            self.random = random.Random()

        if key is not None:
            self.key = key

        else:
            self.key = lambda x: x

    def shuffle(self, array):
        self.random.shuffle(array)

    def uniform(self, start, end):
        return self.random.uniform(start, end)

    def choice(self, array):
        return self.random.choice(array)

    def sample(self, distribution, values=None):
        choice = self.random.random() * sum(distribution)
        i, total = 0, distribution[0]
        while choice > total:
            i += 1
            total += distribution[i]

        return values[i] if values is not None else i
