---
title: "Dropwizard With Loading Cache and Schedular"
date: 2021-02-10T22:03:54-05:00
draft: true
featured: true
tags: ["java", "dropwizard", "dropwizard-jobs", "loading-cache", "parameter store"]
---

# Dropwizard with LoadingCache and Schedular

For past few weeks I was working on an API implementation using dropwizard 2.x. There were following requirements given for the implementation

1. The API implementation should have create a cache by querying db at the startup
2. The cache should be invalidated on request and repopulated

Below shows the architecture diagram for the infrastructure where the code was supposed to be deployed.

![Initial Architecture](/images/post/dropwizard-api-gateway.png)

**Problem Statement**: Clear cache on all the instances by sending a request to the load balancer.

**Problem Analysis**: We can notice here that both EC2 instances are behind a application load balancer and exposed via API Gateway. This serves a unique challenge as if there is an endpoint created to invalidate the cache how to make it sure that when sending the request it is send to both the instances.

**Solution**:

Github Repo: https://github.com/vabs/dropwizard-cache-schedular

Updated Infrastructure Diagram:

![Updated Architecture](/images/post/dropwizard-updated-api-gateway.png)


Below are the following steps taken for this requirement to work.

1. Expose invalidating cache functionality to API endpoint
2. Add a value in AWS Parameter store to serve as a flag representing whose value can be changed when cache needs to be cleared
3. Introduce a CRON task to check if the cache clearing is requested

Now, let's have a look at each step in detail with some code.


### Expose invalidating cache functionality to API endpoint

This was the easiest step as LoadingCache module come with all the methods which were required for this to be exposed.
I created 2 endpoints and exposed them for following functionalites. These functionalites can be exteneded as with per cache object.


| Endpoint | HTTP Type | Description |
|---|---|---|
| `/cache/stats` | GET | Check how the cache is consumed by various requests |
| `/cache/reload` | POST | Invalidate the current cache content and build new cache by querying database |
| `/aws/parameter/<key>` | POST | Sets a new value for specified AWS Parameter |


Code: Mocking AWS Parameter Store

```java
public class AWSProvider {

  public static String parameterStoreValue = "ReplaceMe";

  private static final Logger logger = LoggerFactory.getLogger(AWSProvider.class);

  public static void setParameterStoreValue(String value) {
    logger.info("[AWS Parameter]: Setting new value: " + value);
    parameterStoreValue = value;
  }
}
```


### Add a value in AWS Parameter store

AWS Parameter store serves as the key those value when changed makes the schedular to invalidate the cache and  build a new one
The user can send a post request to `/aws/parameter/<key>` endpoint which will change the value for the parameter as specified in the request


### Writing CRON task

This cron task has a little caveat in the implementation. Since `dropwizard-jobs` runs in a different thread in dropwizard the access to the context objects are not starightforward.
Hence to solve this problem, this cron job calls the localhost process of dropwizard to clear the cache. 

Code: Job running every minute

```java
  public void doJob(JobExecutionContext jobExecutionContext) throws JobExecutionException {
    try {
      String currentValue = retrieveParameterStoreValue();
      if (firstRun) {
        lastValue = currentValue;
        firstRun = false;
        logger.debug("[ForceInvalidationCache Scheduler]: First run. Store '" + currentValue
          + "' as the default value.");
      } else {
        if (!currentValue.equals(lastValue)) {
          // Initial the invalidation of the cache
          logger.info(
            "[ForceInvalidationCache Scheduler]: Parameter Store has changed: '" + lastValue
              + "' != '" + currentValue + "'");
          if (invalidateCache()) {
            // Keep that value for the next time when the cache was cleared successfully
            lastValue = currentValue;
          }
        } // else do nothing, the invalidation with that value has already been done.
        else {
          logger.debug(
            "[ForceInvalidationCache Scheduler]: No change of parameter store -> do nothing.");
        }
      }
    } catch (Exception e) {
      logger.error("[ForceInvalidationCache Scheduler]: Error when parameter store exception");
      e.printStackTrace();
    }
  }
```

Code: Calling localhost to reload cache

```java
protected boolean invalidateCache() {
    logger.debug("[ForceInvalidationCache Scheduler] Invalidating the internal cache via "
      + LOCAL_CLEAR_CACHE_URL);
    try {
      Response response = webTarget.request().get();
      return response != null && response.getStatus() == 200;
    } catch (Exception ex) {
      logger.error(ex.getMessage());
    }
    return false;
  }
```



Here the variable `firstTimeCall` checks if the schedular is running for the first time and sets the value of `currentValue` from AWS Parameter Store.
For the subsequent runs, the AWS Parameter value is checked against the local value and if they don't match the cache is cleared and refilled. If both the values are same, no action is taken.

For my requirement CRON was supposed to run at every 10 mintues interval but it's easy to configure as per the requirement. Checkout [dropwizard-jobs docs](https://github.com/dropwizard-jobs/dropwizard-jobs) for more details


#### References

1. Dropwizard Jobs: https://github.com/dropwizard-jobs/dropwizard-jobs
2. AWS Parameter Store: https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html

