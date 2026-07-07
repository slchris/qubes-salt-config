# test salt



```shell
qubesctl saltutil.sync_all
qubesctl --show-output state.show_top saltenv=user
qubesctl --targets=dom0 state.apply test.test saltenv=user
qubesctl state.highstate saltenv=user
```