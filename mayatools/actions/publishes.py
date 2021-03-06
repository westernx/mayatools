import os

from qbfutures import Executor
from sgactions.utils import notify, progress
from sgfs import SGFS


def get_maya_scene(publish):
    path = publish['sg_path']
    if publish['sg_type'] in ('maya_scene', 'maya_camera'):
        return path
    elif publish['sg_type'] == 'maya_geocache':
        for name in os.listdir(path):
            if os.path.splitext(name)[1] in ('.ma', '.mb') and not name.startswith('.'):
                return os.path.join(path, name)


def republish_scene(entity_type, selected_ids, **kwargs):
    republish(entity_type, selected_ids, 'Scene', 'maya_scene')

def republish_camera(entity_type, selected_ids, **kwargs):
    republish(entity_type, selected_ids, 'Scene', 'maya_camera')

def republish_geocache(entity_type, selected_ids, **kwargs):
    republish(entity_type, selected_ids, 'Scene', 'maya_geocache')


def republish(entity_type, selected_ids, type_name, type_code):

    # no fancy UI needed here
    assert entity_type == 'PublishEvent'
    assert selected_ids

    progress('Fetching entities...')

    sgfs = SGFS()

    entities = [sgfs.session.merge(dict(type=entity_type, id=id_)) for id_ in selected_ids]
    sgfs.session.fetch(entities, ('code', 'sg_link', 'sg_link.Task.entity', 'sg_type', 'sg_path',
        'created_by.HumanUser.login'))

    futures = []
    errors = []

    executor = Executor()

    for i, publish in enumerate(entities):

        if publish['sg_type'] == type_code:
            errors.append('Publish %d is already a %s.' % (publish['id'], type_code))
            continue

        link = publish['sg_link']
        owner = publish.get('sg_link.Task.entity')
        owner_name = owner.name if owner else str(link)
        future_name = 'Republish %s as %s - %s:%s' % (publish['sg_type'], type_code, owner_name, link.name)

        progress('Submitting %s/%s to Qube:\n<em>"%s"</em>' % (i + 1, len(entities), future_name))

        maya_scene = get_maya_scene(publish)

        # Run the job as the original user.
        qb_extra = {}
        login = publish.get('created_by.HumanUser.login')
        if login:
            qb_extra['user'] = login.split('@')[0]

        if type_code == 'maya_scene':
            future = executor.submit_ext('sgpublish.commands.create:main',
                args=[(
                    '--template', str(publish['id']),
                    '--type', type_code,
                    maya_scene
                )],
                name=future_name,
                priority=8000,
                **qb_extra
            )
            futures.append(future)

        elif type_code == 'maya_geocache':
            future = executor.submit_ext('mayatools.geocache.exporter:main',
                args=[(
                    '--publish-template', str(publish['id']),
                    maya_scene,
                )],
                name=future_name,
                interpreter='maya2014_python',
                priority=8000,
                **qb_extra
            )
            futures.append(future)

        elif type_code == 'maya_camera':
            future = executor.submit_ext('mayatools.camera.exporter:main',
                args=[(
                    '--publish-template', str(publish['id']),
                    maya_scene,
                )],
                name=future_name,
                interpreter='maya2014_python',
                priority=8000,
                **qb_extra
            )
            futures.append(future)

        else:
            errors.append('Unknown publish type %r.' % type_code)

    messages = []
    if futures:
        messages.append('Submitted to Qube as %s' % ', '.join(str(f.job_id) for f in futures))
    if errors:
        messages.extend('<span style="color:red">%s</span>' % e for e in errors)
    notify('; '.join(messages))



if __name__ == '__main__':
    
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument('type')
    parser.add_argument('ids', nargs='+', type=int)
    args = parser.parse_args()

    republish('PublishEvent', args.ids, 'Scene', args.type)

