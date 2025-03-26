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
  private static final Logger logger = LoggerFactory.getLogger(FormatClient.class);

  private static String WAREHOUSE_LOCATION;

  @Override
  public void init() throws DBException {
    try {
      final Map<String, String> properties = Maps.newHashMap();
      SupportsAtomicOperations io = s3FileIO(properties); // gcsFileIO(properties);
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

  static ADLSFileIO azureFileIO(Map<String,String> properties) {
    AzureSAS creds =
        AzureSAS.readCreds(new File("/home/chris/work/.cloud/azure/lstnsgym-20250930.json"));
    Map<String, String> azureProperties = new HashMap<>();
    azureProperties.put(
        AzureProperties.ADLS_SAS_TOKEN_PREFIX + "lstnsgym.dfs.core.windows.net", creds.sasToken);

    LocationResolver az = new AzureSAS.SasResolver(creds);
    WAREHOUSE_LOCATION = az.location(YCSB_BUCKET + "/" + UNIQ_RUN);
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);

    final ADLSFileIO azFileIO = new ADLSFileIO();
    azFileIO.initialize(azureProperties);
    return azFileIO;
  }

  static GCSFileIO gcsFileIO(Map<String,String> properties) {
    final File credFile = new File("/home/chris/work/.cloud/gcp/lst-consistency-8dd2dfbea73a.json");
    try (FileInputStream creds = new FileInputStream(credFile)) {
      Storage storage = RemoteStorageHelper.create("lst-consistency", creds).getOptions().getService();
      WAREHOUSE_LOCATION = "gs://" + YCSB_BUCKET + "/" + UNIQ_RUN;
      properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);
      return new GCSFileIO(() -> storage, new GCPProperties());
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  static S3FileIO s3FileIO(Map<String,String> properties) {
    WAREHOUSE_LOCATION = "s3://" + "casalog" + "/" + UNIQ_RUN;
    properties.put(CatalogProperties.WAREHOUSE_LOCATION, WAREHOUSE_LOCATION);
    final S3FileIO s3FileIO = new S3FileIO();
    s3FileIO.initialize(new HashMap<>());
    return s3FileIO;
  }
}
