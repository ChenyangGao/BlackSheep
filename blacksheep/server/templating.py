from functools import lru_cache
from blacksheep.server import Application
from blacksheep import Response, Content
from jinja2 import Environment, Template, PackageLoader, select_autoescape


@lru_cache(1200)
def template_name(name: str):
    if not name.endswith('.html'):
        return name + '.html'
    return name


def get_response(html: str):
    return Response(200, [
        (b'Cache-Control', b'no-cache')
    ]).with_content(Content(b'text/html; charset=utf-8', html.encode('utf8')))


def render_template(template: Template, *args, **kwargs):
    return template.render(*args, **kwargs)


async def render_template_async(template: Template, *args, **kwargs):
    return await template.render_async(*args, **kwargs)


def use_templates(app: Application, loader: PackageLoader, enable_async: bool = False):
    env = app.services['jinja_environment']
    if not env:
        env = Environment(
            loader=loader,
            autoescape=select_autoescape(['html', 'xml']),
            auto_reload=app.debug,
            enable_async=enable_async
        )

        app.services['jinja_environment'] = env
        app.services['jinja'] = env
        env.globals['app'] = app

    if enable_async:
        async def async_view(name: str, *args, **kwargs):
            return get_response(await render_template_async(env.get_template(template_name(name)), *args, **kwargs))

        return async_view

    def sync_view(name: str, *args, **kwargs):
        return get_response(render_template(env.get_template(template_name(name)), *args, **kwargs))

    return sync_view


def view(jinja_environment, name: str, *args, **kwargs):
    """Returns a Response object with HTML obtained from synchronous rendering.

    Use this when `enable_async` is set to False when calling `use_templates`."""
    return get_response(render_template(jinja_environment.get_template(template_name(name)),
                                        *args, **kwargs))


async def view_async(jinja_environment, name: str, *args, **kwargs):
    """Returns a Response object with HTML obtained from synchronous rendering."""
    return get_response(await render_template_async(jinja_environment
                                                    .get_template(template_name(name)), *args, **kwargs))
