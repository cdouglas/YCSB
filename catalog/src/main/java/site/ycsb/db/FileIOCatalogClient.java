package site.ycsb.db;

import com.google.api.client.util.Maps;
import com.google.cloud.storage.Storage;
import com.google.cloud.storage.testing.RemoteStorageHelper;
import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.aws.s3.S3FileIO;
import org.apache.iceberg.azure.AzureProperties;
import org.apache.iceberg.azure.adlsv2.ADLSFileIO;
import org.apache.iceberg.azure.adlsv2.AzureSAS;
import org.apache.iceberg.azure.adlsv2.LocationResolver;
import org.apache.iceberg.gcp.GCPProperties;
import org.apache.iceberg.gcp.gcs.GCSFileIO;
import org.apache.iceberg.io.CASCatalogFormat;
import org.apache.iceberg.io.CatalogFormat;
import org.apache.iceberg.io.FileIOCatalog;
import org.apache.iceberg.io.SupportsAtomicOperations;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import site.ycsb.DBException;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.HashMap;
import java.util.Map;

public class FileIOCatalogClient extends CatalogClient<FileIOCatalog> {
  private static final Logger logger = LoggerFactory.getLogger(FileIOCatalogClient.class);

  private static String WAREHOUSE_LOCATION;

  static final String FILEIO_STORE = "fileio.store";
  static final String BUCKET_NAME = "fileio.bucket";

  @Override
  public void init() throws DBException {
    String bucket = getProperties().getOrDefault(BUCKET_NAME, YCSB_BUCKET).toString();
    try {
      final Map<String, String> properties = Maps.newHashMap();
      final SupportsAtomicOperations io;
        Object o = getProperties().get(FILEIO_STORE);
        if ("aws".equals(o)) {
          // TODO hack for testing, plumb this correctly
          bucket = "lst-pbafvfgrapl--usw2-az3--x-s3"; // s3 express bucket
          io = s3FileIO(bucket, properties);
          System.out.println("### S3 ###");
        } else if ("gcp".equals(o)) {
          io = gcsFileIO(bucket, properties);
          System.out.println("### GCS ###");
        } else if ("azure".equals(o)) {
          io = azureFileIO(bucket, properties);
          System.out.println("### AZURE ###");
        } else {
            throw new IllegalArgumentException("Unknown fileio object: " + getProperties().get(FILEIO_STORE));
        }
      final String catalogLoc = WAREHOUSE_LOCATION + "/catalog";
      logger.info("WAREHOUSE: {}", WAREHOUSE_LOCATION);
      synchronized (FileIOCatalogClient.class) {
        final CatalogFormat<?,?> format = new CASCatalogFormat();
        // create empty catalog
        // format.empty(io.newInputFile(catalogLoc)).commit(io);
        catalog = new FileIOCatalog("test", catalogLoc, null, format, io, Maps.newHashMap());
        catalog.initialize("YCSB-Bench", properties);
        initTables();
      }
    } catch (Exception e){
      throw new DBException("Failed to load remote / init storage or catalog", e);
    }
  }

  static ADLSFileIO azureFileIO(String bucket, Map<String,String> properties) {
    final File credFile = new File("/home/chris/work/.cloud/azure/lstnsgym-20250930.json");
    final LocationResolver az;
    final Map<String, String> azureProperties = new HashMap<>();
    if (credFile.exists()) {
      AzureSAS creds =
              AzureSAS.readCreds(credFile);
      azureProperties.put(
              AzureProperties.ADLS_SAS_TOKEN_PREFIX + "lstnsgym.dfs.core.windows.net", creds.sasToken);

      az = new AzureSAS.SasResolver(creds);
    } else {
      // TODO this is a dumb and lazy way to do this.
      String accountName = System.getenv("AZURE_STORAGE_ACCOUNT");
      String containerName = System.getenv("AZURE_STORAGE_CONTAINER");
      az = new HackOnAHack(accountName, containerName);
    }
    final String prefix = properties.get(FileIOClient.TEST_RUN);
    WAREHOUSE_LOCATION = az.location(bucket + "/" + prefix);
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);

    final ADLSFileIO azFileIO = new ADLSFileIO();
    azFileIO.initialize(azureProperties);
    return azFileIO;
  }

  static GCSFileIO gcsFileIO(String bucket, Map<String,String> properties) {
    final File credFile = new File("/home/chris/work/.cloud/gcp/lst-consistency-8dd2dfbea73a.json");
    final String prefix = properties.get(FileIOClient.TEST_RUN);
    WAREHOUSE_LOCATION = "gs://" + bucket + "/" + prefix;
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);
    if (credFile.exists()) {
      try (FileInputStream creds = new FileInputStream(credFile)) {
        Storage storage = RemoteStorageHelper.create("lst-consistency", creds).getOptions().getService();
        return new GCSFileIO(() -> storage, new GCPProperties());
      } catch (IOException e) {
        throw new UncheckedIOException(e);
      }
    }
    final GCSFileIO ret = new GCSFileIO();
    ret.initialize(properties);
    return ret;
  }

  static S3FileIO s3FileIO(String bucket, Map<String,String> properties) {
    // TODO elide UNIQ_RUN if FILE_NAME is set
    final String prefix = properties.get(FileIOClient.TEST_RUN);
    WAREHOUSE_LOCATION = "s3://" + bucket + "/" + prefix;
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);
    final S3FileIO s3FileIO = new S3FileIO();
    s3FileIO.initialize(new HashMap<>());
    return s3FileIO;
  }
}
