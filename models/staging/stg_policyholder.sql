with crm as (
    select
        'CRM'                       as source_system,
        cust_id                     as customer_id,
        cust_name                   as name_raw,
        dob                         as date_of_birth,
        upper(trim(gender_cd))      as gender_raw,
        email                       as email_raw,
        phone_no                    as phone_raw,
        city                        as city_raw,
        pincode                     as pincode_raw,
        upper(trim(segment_cd))     as segment_raw,
        upper(trim(marital_cd))     as marital_raw,
        upper(trim(kyc_status))     as kyc_raw,
        upper(trim(status))         as status_raw,
        customer_since,
        last_modified_ts            as change_ts
    from {{ source('curated', 'crm_policyholder') }}
),

web as (
    select
        'WEB'                       as source_system,
        customer_ref                as customer_id,
        full_name                   as name_raw,
        birth_date                  as date_of_birth,
        upper(trim(gender))         as gender_raw,
        email_id                    as email_raw,
        phone                       as phone_raw,
        town                        as city_raw,
        postcode                    as pincode_raw,
        upper(trim(tier))           as segment_raw,
        null::varchar               as marital_raw,   -- not captured by WEB
        null::varchar               as kyc_raw,       -- not captured by WEB
        'A'                         as status_raw,    -- WEB sends active customers only
        signup_date                 as customer_since,
        updated_on                  as change_ts
    from {{ source('curated', 'web_policyholder') }}
),

unioned as (
    select * from crm
    union all
    select * from web
),

cleaned as (
    select
        source_system,
        trim(customer_id)                                         as customer_id,
        initcap(regexp_replace(trim(name_raw), '\\s+', ' '))     as customer_name,   -- BR-01
        date_of_birth,
        case                                                                          -- BR-07
            when gender_raw in ('M', 'MALE')   then 'Male'
            when gender_raw in ('F', 'FEMALE') then 'Female'
            when gender_raw in ('O', 'OTHER')  then 'Other'
            else 'Unknown'
        end                                                       as gender,
        lower(trim(email_raw))                                    as email_clean,     -- BR-04
        regexp_replace(phone_raw, '[^0-9]', '')                   as phone_digits,    -- BR-05
        initcap(trim(city_raw))                                   as city_proper,     -- BR-02
        iff(regexp_like(trim(pincode_raw), '^[0-9]{6}$'), trim(pincode_raw), null)
                                                                  as pincode,         -- BR-03
        case                                                                          -- BR-06
            when segment_raw in ('R', 'RETAIL')    then 'Retail'
            when segment_raw in ('P', 'PREMIUM')   then 'Premium'
            when segment_raw in ('C', 'CORPORATE') then 'Corporate'
            else 'Unknown'
        end                                                       as segment,
        case marital_raw                                                              -- BR-08
            when 'S' then 'Single'   when 'M' then 'Married'
            when 'D' then 'Divorced' when 'W' then 'Widowed'
            else 'Unknown'
        end                                                       as marital_status,
        case kyc_raw                                                                  -- BR-11
            when 'V' then 'Verified' when 'P' then 'Pending' when 'R' then 'Rejected'
            else 'Unknown'
        end                                                       as kyc_status,
        iff(status_raw = 'I', 'INACTIVE', 'ACTIVE')               as record_status,   -- BR-13
        customer_since,
        email_raw, phone_raw, pincode_raw,
        change_ts
    from unioned
),

validated as (
    select
        *,
        iff(regexp_like(email_clean, '^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$'),
            email_clean, null)                                    as email_valid,
        case
            when length(phone_digits) = 10                                    then phone_digits
            when length(phone_digits) = 12 and startswith(phone_digits, '91') then right(phone_digits, 10)
            when length(phone_digits) = 11 and startswith(phone_digits, '0')  then right(phone_digits, 10)
        end                                                       as phone_valid,
        case city_proper
            when 'Bangalore' then 'Bengaluru'  when 'Bombay'   then 'Mumbai'
            when 'Madras'    then 'Chennai'    when 'Calcutta' then 'Kolkata'
            when 'Gurgaon'   then 'Gurugram'
            else city_proper
        end                                                       as city
    from cleaned
)

select
    source_system,
    customer_id,
    customer_name,
    date_of_birth,
    gender,
    left(email_valid, 1) || '***' || substr(email_valid, position('@' in email_valid)) as email_masked, -- BR-12
    md5(email_valid)                                              as email_hash,
    'XXXXXX' || right(phone_valid, 4)                             as phone_masked,
    md5(phone_valid)                                              as phone_hash,
    city,
    pincode,
    segment,
    marital_status,
    kyc_status,
    record_status,
    customer_since,
    nullif(array_to_string(array_construct_compact(                                   -- BR-15
        iff(email_raw   is not null and email_valid is null, 'INVALID_EMAIL',   null),
        iff(phone_raw   is not null and phone_valid is null, 'INVALID_PHONE',   null),
        iff(pincode_raw is not null and pincode     is null, 'INVALID_PINCODE', null),
        iff(date_of_birth is null,                           'MISSING_DOB',     null)
    ), ', '), '')                                                 as dq_reason,
    iff(dq_reason is null, 'VALID', 'WARNING')                    as dq_status,
    change_ts
from validated
where customer_id is not null and customer_id <> ''                                   -- BR-14