import unittest
from usable_time_parser import *
from data_structure import *
from engine import *
import test_util
test_util.allow_parent_import()


class EngineTest(unittest.TestCase):

    def test_engine(self):
        task1 = Task()
        task1.id.value = 1
        task1.start = Date().decode_self('2018-12-01')
        task1.end = Date().decode_self('2018-12-05')
        task1.amount.value = 600
        task1.done.value = 0
        task2 = Task()
        task2.id.value = 2
        task2.start = Date().decode_self('2018-12-01')
        task2.end = Date().decode_self('2018-12-04')
        task2.amount.value = 600
        task2.done.value = 120
        task3 = Task()
        task3.id.value = 3
        task3.start = Date().decode_self('2018-12-02')
        task3.end = Date().decode_self('2018-12-05')
        task3.amount.value = 600
        task3.done.value = 300
        task4 = Task()
        task4.id.value = 4
        task4.start = Date().decode_self('2018-12-02')
        task4.end = Date().decode_self('2018-12-05')
        task4.amount.value = 60
        task4.done.value = 60
        task5 = Task()
        task5.id.value = 5
        task5.start = Date().decode_self('2018-11-25')
        task5.end = Date().decode_self('2018-12-03')
        task5.amount.value = 720
        task5.done.value = 0
        tasks = [task1, task2, task3, task4, task5]

        for task in tasks:
            task.parse_urgency()

        ds1 = DatedSession()
        ds1.date = Date().decode_self('2018-12-02')
        ds1.session.id.value = 1
        ds1.session.amount.value = 50
        ds1.session.weakness.value = SessionWeaknessEnum.STRONG
        ds2 = DatedSession()
        ds2.date = Date().decode_self('2018-11-28')
        ds2.session.id.value = 5
        ds2.session.amount.value = 50
        ds2.session.weakness.value = SessionWeaknessEnum.STRONG
        ds3 = DatedSession()
        ds3.date = Date().decode_self('2018-10-28')
        ds3.session.id.value = 5
        ds3.session.amount.value = 50
        ds3.session.weakness.value = SessionWeaknessEnum.STRONG
        dated_sessions = [ds1, ds2, ds3]

        schedule_start = Date().decode_self('2018-11-30')
        schedule_end = Date().decode_self('2018-12-06')
        usable_time_config = [UsableTimeConfigEntry().decode_self(
            {'selector': 'default', 'duration': 480})]

        fragmentation_config = FragmentationConfig()
        fragmentation_config.max_percentage.value = 0.2
        fragmentation_config.min_extra_time_ratio.value = 0.8
        fragmentation_config.preferred_fragment_size.value = 60
        fragmentation_config.min_fragment_size.value = 30

        config = Config()
        config.today = schedule_start
        config.scheduling_days.value = 10
        config.daily_info_days.value = 8
        config.fragmentation_config = fragmentation_config
        config.random_power.value = 1
        config.default_urgency.value = 40
        scheduling_request = SchedulingRequest()
        scheduling_request.config = config
        scheduling_request.tasks = tasks
        scheduling_request.usable_time = usable_time_config
        scheduling_request.dated_sessions = dated_sessions

        engine = Engine.create()
        r = engine.schedule(scheduling_request).encode()
        # print(r)
        # For now this simply tests if there are any obvious error.


if __name__ == '__main__':
    unittest.main()
