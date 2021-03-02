---
title: "Canonical Data Model"
date: 2018-05-30T21:59:50-04:00
draft: false
featured: false
tags: ["micro-services", "canonical data model", "api"]
---

### Definition
> It's the model is a design pattern which defines the communication protocol between various enterprise systems.


With software industry switching focus from monolithic apps to micro-services, there is always a need for the better communication model between each other. Most of the API based connectivity is architect for following proper REST principles and single responsibility. There is not much thought given for the communication model between the services.

Been in a team of 20 software engineers, I have experienced that every developer has a way to write the definition for the service.

For example:

Definition for Output from a service:
```
{
    "output_property_1": "output_value_1",
    "output_property_2": "output_value_2",
    "output_property_3": "output_value_3",
    "output_property_4": "output_value_4",
    "control_parameter_1": "control_value_1",
    "control_parameter_2": "control_value_2"
}
``` 

The same definition by another developer can be written as

```
{
    "output": {
        "properties": {
            "output_property_1": "output_value_1",
            "output_property_2": "output_value_2",
            "output_property_3": "output_value_3",
            "output_property_4": "output_value_4"    
        },
        "controls": {
            "control_parameter_1":  "control_value_1",
            "control_parameter_2":  "control_value_2"
        }
    }
}
```

The merits of first definition is that it is easy to develope and if need any new property just can be added to the output response json. Though extending the output will result into more cluttering of unused and properties.

This is where the second approach is better as there is grouping of same types of output parameters. This also gives a lot of extensibility as if a new response type is to be added or an existing is to be removed.

Though as the service mature the second approach also reaches a point where it's difficult to maintain. There are issues with backward compatibility as some output parameters now might be obsolete but still exists in the response. Also the new versions of API it's becomes difficult not to introduce breaking changes.

Let's see a different approach to overcome this issue. The response has to be a standard format which can be emulated by every service in the same domain. It should have extensibility and scalability.

```
{
    "message": {
        "header": {
            "version": 1.0,
            ...
        },
        "body": {
            "output": {
                "properties": {
                    "output_property_1": "output_value_1",
                    "output_property_2": "output_value_2",
                    "output_property_3": "output_value_3",
                    "output_property_4": "output_value_4"    
                },
                "controls": {
                    "control_parameter_1":  "control_value_1",
                    "control_parameter_2":  "control_value_2"
                }
            }
        }
    }
}
```

------


**Standard format response**
```
{
    "message": {
        "header": {
            "version": 1.0,
            ...
        },
        "body": {
            ...
        }
    }
}
```


First of all we see the version in the response header. As the new versions of the service are released, the output response should also reflect the same. In this way, the consumer is always confident about the output format of the response.
There can be more parameters added to the response header which can; for example reflect how the message was generated and/or about the entity object in the `body` property.

------

This approach can be standardized for all the domain in the organization. In result, it will define the mechanism in which domains communicate with each other.


## Gotchas
As someone said, nothing is perfect. Here are a few things to be considered when using this approach.

* The canonical model is a transport model, hence should not contain or support any business rules.
* The system generating the message is not required to generated all the values in the model. It should just generate what is defined in the system.
* The model should be kept updated with the service versions as to fulfill the contract between domain.
* The consumer of the model should check about the expected version to ensure the correctness.