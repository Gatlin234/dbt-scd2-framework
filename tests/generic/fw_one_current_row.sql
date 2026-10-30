{% test fw_one_current_row(model, column_name) %}
select {{ column_name }}, count(*) as active_versions
from {{ model }}
where is_current = 'Y'
group by {{ column_name }}
having count(*) > 1
{% endtest %}