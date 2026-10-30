{% test fw_versions_are_continuous(model, column_name) %}
select *
from (
    select
        {{ column_name }}, valid_from, valid_to,
        lead(valid_from) over (partition by {{ column_name }} order by valid_from) as next_from
    from {{ model }}
)
where next_from is not null
  and valid_to <> next_from
{% endtest %}