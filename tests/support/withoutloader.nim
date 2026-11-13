## [I89; plan §2.14] Every engine has the Module Loader instance
## (`LoaderInstanceId`), established at open before any other. Suites about
## other instances compare inventories without it.

{.push raises: [].}

from ../../src/logos_core/loader/contract import LoaderInstanceId

export LoaderInstanceId

func withoutLoader*[T](items: openArray[T]): seq[T] =
  ## `items` in order, less the Loader's: views by their `instance` or `id`,
  ## changes by their view's, strings as instance ids.
  for it in items:
    when T is string:
      if it != LoaderInstanceId:
        result.add(it)
    elif compiles(it.instance):
      if it.instance != LoaderInstanceId:
        result.add(it)
    elif compiles(it.view.instance):
      if it.view.instance != LoaderInstanceId:
        result.add(it)
    else:
      if it.id != LoaderInstanceId:
        result.add(it)

{.pop.}
